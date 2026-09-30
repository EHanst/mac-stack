#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import AppKit

/// Center column: pick a brief, edit its sections. The compiled prompt is on the right.
struct BriefWorkbenchView: View {
    @Environment(AppServices.self) private var services
    @State private var newTitle = ""
    @State private var creating = false
    @State private var improving = false
    @State private var clipboardNote: String?
    @State private var continuing = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(spacing: 0) {
            header
            continuationStatus
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
        .sheet(isPresented: $improving) { improveSheet }
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
                ForEach(model.briefs) { Text($0.title).tag(Optional($0.id)) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SidecarRailView()
                ForEach(BriefSection.Kind.allCases, id: \.self) { kind in
                    sectionEditor(kind, section: brief.sections.first { $0.kind == kind })
                }
            }
            .padding(16)
        }
    }

    private func sectionEditor(_ kind: BriefSection.Kind, section: BriefSection?) -> some View {
        let enabled = section?.enabled ?? true
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.title(kind)).font(.mtLabelLarge)
                Text("~\(PromptTokens.estimate(section?.text ?? "")) tokens")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                if kind == .goal {
                    Button("Improve") { improveGoal() }
                        .disabled((section?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                Toggle("Include", isOn: Binding(get: { enabled }, set: { model.setEnabled($0, for: kind) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            TextEditor(text: Binding(get: { section?.text ?? "" }, set: { model.setText($0, for: kind) }))
                .font(.mtBodyMedium)
                .frame(minHeight: kind == .goal ? 110 : 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .opacity(enabled ? 1 : 0.5)
            if kind == .goal, enabled, let id = model.selectedID, let target = model.selected?.target {
                ForEach(PromptLint.check(section?.text ?? "", context: .init(maxTokens: target.tokenBudget))) { finding in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Color.mtOnSurfaceVariant)
                        Text(finding.message).font(.mtBodySmall)
                        // "Name the file" has no text worth inserting; a blank "File:" would only repeat.
                        if let add = finding.suggestion, finding.rule != .noTarget {
                            Button("Add") { model.append(add.trimmingCharacters(in: .whitespacesAndNewlines), to: .goal, briefID: id) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Text(Self.hint(kind)).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            if kind == .context { ContextListView() }
        }
    }

    private var goalText: String { model.selected?.text(of: .goal) ?? "" }

    private func improveGoal() {
        services.promptStudio.startOptimize(draft: goalText, mode: .improve, intent: PromptEngineer.Intent.general.rawValue)
        improving = true
    }

    private var improveSheet: some View {
        OptimizeReviewSheet(
            studio: services.promptStudio, draft: goalText,
            onAccept: { model.setText($0, for: .goal); services.promptStudio.clearUndo(); improving = false },
            onExpand: { services.promptStudio.startOptimize(draft: goalText, mode: .expand, intent: PromptEngineer.Intent.general.rawValue) },
            onAskQuestions: { questions in
                model.setText(goalText + "\n\n" + questions.map { "Q: \($0)\nA: " }.joined(separator: "\n"), for: .goal)
                services.promptStudio.dismissReview(); improving = false
            },
            onClose: { services.promptStudio.dismissReview(); improving = false })
    }

    static func title(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "Goal"
        case .context: "Context"
        case .constraints: "Constraints"
        case .examples: "Examples"
        case .outputFormat: "Output format"
        }
    }

    static func hint(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "What you want done, in your own words."
        case .context: "Background the model cannot see on its own."
        case .constraints: "Rules it must follow, one per line."
        case .examples: "A sample of what good looks like."
        case .outputFormat: "How the answer should be shaped."
        }
    }
}
#endif
