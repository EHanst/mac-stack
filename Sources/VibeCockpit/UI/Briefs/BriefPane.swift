#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI
import AppKit

/// Right column: exactly what the frontier model will receive, plus target, editable brief, Improve, and Copy.
struct BriefPane: View {
    @Environment(AppServices.self) private var services
    @State private var copied = false
    @State private var showVersions = false
    @State private var showImprove = false
    @State private var improveID: String?
    @State private var exportRoots: [URL] = []
    @State private var exportMessage: String?

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        if let brief = model.selected, let compiled = model.compiled {
            VStack(alignment: .leading, spacing: 12) {
                targetPicker(brief)
                meter(brief, compiled)
                statusLine(brief)
                editor(brief)
                attachmentsFooter(brief)
                ForEach(Array(compiled.warnings.enumerated()), id: \.offset) { _, w in
                    Label(w.message, systemImage: "exclamationmark.triangle")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                copyBar
                if let exportMessage {
                    Text(exportMessage).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
            .padding(16)
            .sheet(isPresented: $showVersions) {
                BriefVersionsSheet(brief: brief, onRestore: { model.restoreVersion($0) }, onClose: { showVersions = false })
            }
            .sheet(isPresented: $showImprove) { improveSheet(brief) }
            .task(id: model.selectedID) { exportMessage = nil; exportRoots = await model.exportRoots() }
            .background(Color.mtSurfaceContainerLowest)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 40))
                    .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
                Text("The finished prompt shows here").font(.mtTitleMedium)
                    .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mtSurfaceContainerLowest)
        }
    }

    @ViewBuilder
    private func statusLine(_ brief: Brief) -> some View {
        if brief.body == nil {
            Text("Linked to input")
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)
        } else {
            HStack(spacing: 8) {
                Text("Edited")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                Button("Rebuild from input") { model.rebuildFromInput() }
                    .controlSize(.small)
                if model.inputChangedSinceEdit {
                    Text("Input changed since you edited the brief")
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtError)
                }
            }
        }
    }

    private func editor(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brief").font(.mtLabelLarge)
                Text("~\(PromptTokens.estimate(brief.effectiveBody)) tokens")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Spacer()
                Button("Improve") { openImprove(brief) }
                    .disabled(brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            EchoGuardedEditor(external: brief.effectiveBody) { model.setBody($0) }
                .id("\(brief.id)-body")
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func attachmentsFooter(_ brief: Brief) -> some View {
        let included = brief.contextItems.filter(\.included)
        if !included.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attachments").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                ForEach(included) { item in
                    Text("\(item.ref) (~\(item.tokens) tokens, \(item.mode == .inline ? "inline" : "by path"))")
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
        }
    }

    private func openImprove(_ brief: Brief) {
        improveID = brief.id
        services.promptStudio.startOptimize(draft: brief.effectiveBody, mode: .improve,
                                            intent: PromptEngineer.Intent.general.rawValue)
        showImprove = true
    }

    private func improveSheet(_ brief: Brief) -> some View {
        let draft = brief.effectiveBody
        let id = improveID
        return OptimizeReviewSheet(
            studio: services.promptStudio,
            draft: draft,
            onAccept: { if let id { model.setBody($0, briefID: id) }; services.promptStudio.clearUndo(); showImprove = false },
            onExpand: { services.promptStudio.startOptimize(draft: draft, mode: .expand,
                                                           intent: PromptEngineer.Intent.general.rawValue) },
            onAskQuestions: { questions in
                if let id { model.appendToBody(questions.map { "Q: \($0)\nA: " }.joined(separator: "\n"), briefID: id) }
                services.promptStudio.dismissReview()
                showImprove = false
            },
            onClose: {
                improveID = nil
                services.promptStudio.dismissReview()
                showImprove = false
            })
    }

    private func targetPicker(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(get: { brief.target.modelFamily },
                                               set: { model.setTarget(modelFamily: $0, surface: brief.target.surface) })) {
                Text("Claude").tag("claude"); Text("GPT").tag("gpt"); Text("Other").tag("generic")
            }
            Picker("Where", selection: Binding(get: { brief.target.surface },
                                               set: { model.setTarget(modelFamily: brief.target.modelFamily, surface: $0) })) {
                ForEach(Surface.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        .pickerStyle(.menu)
    }

    private func meter(_ brief: Brief, _ compiled: CompiledPrompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(Double(compiled.tokens), Double(brief.target.tokenBudget)),
                         total: Double(max(brief.target.tokenBudget, 1)))
            Text("About \(compiled.tokens.formatted()) of \(brief.target.tokenBudget.formatted()) tokens")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private var copyBar: some View {
        let empty = !model.canCopy
        return HStack {
            Button { copy(nil) } label: { Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                .buttonStyle(MTFilledButtonStyle())
                .disabled(empty)
            Menu("Copy for…") {
                Button("Claude Code") { copy(.claudeCode) }
                Button("ChatGPT") { copy(.chatGPTWeb) }
            }
            .disabled(empty)
            Menu("Save to project") {
                ForEach(exportRoots, id: \.self) { root in
                    Button(root.lastPathComponent) { exportMessage = model.exportSelected(to: root) }
                }
                if exportRoots.isEmpty { Text("Add a project first") }
            }
            .disabled(empty)
            .onHover { if $0 { Task { exportRoots = await model.exportRoots() } } }
            Button("Versions") { showVersions = true }
                .disabled(model.selected?.versions.isEmpty ?? true)
        }
    }

    private func copy(_ surface: Surface?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyForClipboard(for: surface), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
#endif
