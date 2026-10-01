#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import AppKit

/// Center column: pick a brief, edit the input. The compiled prompt is on the right.
struct BriefWorkbenchView: View {
    @Environment(AppServices.self) private var services
    @State private var newTitle = ""
    @State private var creating = false
    @State private var clipboardNote: String?
    @State private var continuing = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(spacing: 0) {
            header
            continuationStatus
            KnowledgePromptView()
            if let clipboardNote {
                Text(clipboardNote).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            MTDivider()
            if let brief = model.selected {
                editor(brief)
            } else {
                emptyState
            }
        }
        .background(Color.mtSurface)
        .sheet(isPresented: $continuing) {
            ReplySheet(title: "Continue from a session",
                       prompt: "Paste a long session. The sidecar summarizes it into a new brief; the paste is not kept.",
                       action: "Make brief",
                       onSubmit: { services.sidecar.continueFromSession($0, in: model) },
                       onClose: { continuing = false })
        }
        .task { await model.reload() }
        .onChange(of: model.selectedID) {
            clipboardNote = nil
            if case .failed = services.sidecar.continuationPhase { services.sidecar.cancelContinuation() }
        }
        .onDisappear { Task { await model.flushNow() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Brief", selection: Binding(get: { model.selectedID }, set: { model.select($0); services.sidecar.clear() })) {
                if model.briefs.isEmpty { Text("No briefs").tag(String?.none) }
                ForEach(model.briefs) { Text($0.isDraft ? "\($0.title) (draft)" : $0.title).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .disabled(model.briefs.isEmpty)
            Spacer()
            Menu {
                Button("New brief") { creating = true }
                Button("New brief from clipboard") { fromClipboard() }
                Button("New brief from a pasted session…") { continuing = true }
            } label: { Label("New brief", systemImage: "plus") }
                .menuStyle(.button)
            Button(role: .destructive) { Task { await model.deleteSelected(); if model.selected == nil || model.selectedID != services.sidecar.briefID { services.sidecar.clear() } } } label: { Image(systemName: "trash") }
                .disabled(model.selected == nil)
                .help("Delete this brief")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .alert("New brief", isPresented: $creating) {
            TextField("What is it for?", text: $newTitle)
            Button("Create") { let t = newTitle; newTitle = ""; Task { await model.newBrief(title: t) } }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
    }

    @ViewBuilder private var continuationStatus: some View {
        switch services.sidecar.continuationPhase {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing the session…").font(.mtBodySmall)
                Button("Cancel") { services.sidecar.cancelContinuation() }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
                Button { services.sidecar.cancelContinuation() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
        case .idle:
            EmptyView()
        }
    }

    private func fromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        Task {
            if await model.newBrief(fromClipboard: text) { clipboardNote = nil; services.sidecar.clear() }
            else { clipboardNote = "The clipboard has no text." }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
            Text("No briefs yet").font(.mtTitleMedium)
            Text("A brief is the prompt you will hand to Claude Code, Cursor or ChatGPT. Start one and shape it here.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            Button("New brief") { creating = true }.buttonStyle(MTFilledButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editor(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CappedScroll {
                VStack(alignment: .leading, spacing: 8) {
                    BrainstormBanner()
                    SidecarRailView()
                }
            }
            HStack {
                Text("Input").font(.mtLabelLarge)
                Button("⌘↩ to improve") { services.improve.open(brief.input, brief: brief, studio: services.promptStudio) }
                    .buttonStyle(.plain)
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(brief.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Improve this brief (Command-Return)")
                Text("~\(PromptTokens.estimate(brief.input)) tokens")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            EchoGuardedEditor(external: brief.input) { model.setInput($0) }
                .id("\(brief.id)-input")
                .font(.mtBodyMedium)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 160, maxHeight: .infinity)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            CappedScroll {
                VStack(alignment: .leading, spacing: 4) { lintRows(brief) }
            }
            CappedScroll { ContextListView() }
        }
        .padding(16)
    }

    @ViewBuilder
    private func lintRows(_ brief: Brief) -> some View {
        ForEach(PromptLint.check(brief.input, context: .init(maxTokens: brief.target.tokenBudget))) { finding in
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.mtOnSurfaceVariant)
                Text(finding.message).font(.mtBodySmall)
                // "Name the file" has no text worth inserting; a blank "File:" would only repeat.
                if let add = finding.suggestion, finding.rule != .noTarget {
                    Button("Add") { model.appendToInput(add.trimmingCharacters(in: .whitespacesAndNewlines), briefID: brief.id) }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Only as tall as its content, up to `maxHeight`; beyond that it scrolls. Keeps short rows from
/// leaving a gap and long ones from pushing the editor or copy bar out of view.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat = 220
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, h in contentHeight = h }
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
    }
}
#endif
