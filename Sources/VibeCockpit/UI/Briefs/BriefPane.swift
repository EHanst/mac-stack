#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI
import AppKit

/// Right column: the editable brief (linked to the input or hand-edited) plus its attachments, with target, Improve, and Copy.
/// The model receives the compiled text (brief plus attachments), not this editor's raw contents.
struct BriefPane: View {
    @Environment(AppServices.self) private var services
    private enum CopyKind: String { case machine, standard }
    @State private var copied: CopyKind?
    private enum ViewMode: String { case markdown = "Markdown", machine = "Machine" }
    @AppStorage("brief.viewMode") private var viewModeStorage: String = ViewMode.markdown.rawValue
    @AppStorage("brief.primaryCopy") private var primaryCopyStorage: String = CopyKind.machine.rawValue
    @State private var showVersions = false
    @State private var showReplySheet = false
    @State private var exportRoots: [URL] = []
    @State private var exportMessage: String?
    @State private var copyNote: String?

    private var model: BriefWorkbenchModel { services.briefs }
    private var improve: BriefImproveModel { services.improve }
    private var feedback: BriefFeedbackModel { services.feedback }

    private var viewMode: ViewMode {
        get { ViewMode(rawValue: viewModeStorage) ?? .markdown }
        nonmutating set { viewModeStorage = newValue.rawValue }
    }

    private var primaryCopy: CopyKind {
        get { CopyKind(rawValue: primaryCopyStorage) ?? .machine }
        nonmutating set { primaryCopyStorage = newValue.rawValue }
    }

    var body: some View {
        if let brief = model.selected, let compiled = model.compiled {
            VStack(alignment: .leading, spacing: 12) {
                targetPicker(brief)
                meter(brief, compiled)
                statusLine(brief)
                editor(brief, compiled: compiled)
                CappedScroll(maxHeight: 160) {
                    VStack(alignment: .leading, spacing: 8) {
                        attachmentsFooter(brief)
                        ForEach(Array(compiled.warnings.enumerated()), id: \.offset) { _, w in
                            Label(w.message, systemImage: "exclamationmark.triangle")
                                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                        }
                    }
                }
                BriefFeedbackBar(brief: brief)
                copyBar
                if let copyNote {
                    Text(copyNote)
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                }
                if let exportMessage {
                    Text(exportMessage).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
            .padding(16)
            .sheet(isPresented: $showVersions) {
                BriefVersionsSheet(brief: brief, onRestore: { model.restoreVersion($0) }, onClose: { showVersions = false })
            }
            .sheet(isPresented: $showReplySheet) {
                ReplySheet(title: "Paste reply",
                           prompt: "Paste the assistant's reply; it will be added to the brief under “Previous reply”.",
                           action: "Add reply",
                           onSubmit: { addReply($0) },
                           onClose: { showReplySheet = false })
            }
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

    private func editor(_ brief: Brief, compiled: CompiledPrompt) -> some View {
        let machine = viewMode == .machine
        let machineText = machine ? model.copyText(for: nil, compact: true) : ""
        let empty = brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let plainTokens = compiled.tokens
        let compactTokens = BriefCompiler.compile(brief, compact: true).tokens
        let savings = TokenSavings.percent(plain: plainTokens, compact: compactTokens)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brief").font(.mtLabelLarge)
                Picker("View", selection: Binding(
                    get: { viewMode },
                    set: { viewMode = $0 }
                )) {
                    ForEach([ViewMode.markdown, .machine], id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("~\(machine ? PromptTokens.estimate(machineText) : plainTokens) tokens")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Text("Machine ~\(compactTokens) tokens (saves \(savings)%)")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Spacer()
                Button("Improve") { improve.open(brief, studio: services.promptStudio) }
                    .disabled(empty || machine)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("") { viewMode = viewMode == .markdown ? .machine : .markdown }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .frame(width: 0, height: 0)
                    .hidden()
            }
            if machine {
                ScrollView {
                    Text(machineText.isEmpty ? "Nothing to show yet." : machineText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Read-only: what Copy for machine puts on the clipboard, attachments included. Switch to Markdown to edit.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            } else {
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
    }

    @ViewBuilder
    private func attachmentsFooter(_ brief: Brief) -> some View {
        let included = brief.contextItems.filter(\.included)
        if !included.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attachments").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                ForEach(included) { item in
                    HStack {
                        Text("\(item.ref) (~\(item.tokens) tokens)")
                            .font(.mtBodySmall)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                        Spacer()
                        Toggle(item.mode == .inline ? "inline" : "by path", isOn: Binding(
                            get: { item.mode == .inline },
                            set: { model.setContextMode($0 ? .inline : .reference, id: item.id) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(item.ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text("Attachments ~\(included.reduce(0) { $0 + $1.tokens }) of \(brief.target.tokenBudget) tokens")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
        }
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
            if primaryCopy == .machine {
                Button { copy(nil, compact: true) } label: {
                    Label(copied == .machine ? "Copied" : "Copy for machine", systemImage: "cpu")
                }
                .buttonStyle(MTFilledButtonStyle())
                .help("Compact, data-dense text that uses fewer tokens")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(empty)
                Button { copy(nil) } label: { Label(copied == .standard ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(empty)
            } else {
                Button { copy(nil) } label: { Label(copied == .standard ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(MTFilledButtonStyle())
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(empty)
                Button { copy(nil, compact: true) } label: {
                    Label(copied == .machine ? "Copied" : "Copy for machine", systemImage: "cpu")
                }
                .help("Compact, data-dense text that uses fewer tokens")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(empty)
            }
            Menu("Copy for…") {
                Button("Claude Code") { copy(.claudeCode) }
                Button("ChatGPT") { copy(.chatGPTWeb) }
            }
            .disabled(empty)
            Menu("Primary button") {
                Button(primaryCopy == .machine ? "✓ Copy for machine" : "Copy for machine") {
                    primaryCopyStorage = CopyKind.machine.rawValue
                }
                Button(primaryCopy == .standard ? "✓ Copy" : "Copy") {
                    primaryCopyStorage = CopyKind.standard.rawValue
                }
            }
            Button("Paste reply") { showReplySheet = true }
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

    private func copy(_ surface: Surface?, compact: Bool = false) {
        guard let brief = model.selected else { return }
        let compiledForCopy = BriefCompiler.compile(brief, compact: compact)
        let text = model.copyForClipboard(for: surface, compact: compact)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = compact ? .machine : .standard
        let secretWord = compiledForCopy.redactedCount == 1 ? "secret" : "secrets"
        copyNote = "\(compact ? "Copied for machine" : "Copied"), ~\(compiledForCopy.tokens) tokens, \(compiledForCopy.redactedCount) \(secretWord) redacted"
        Task { try? await Task.sleep(for: .seconds(2)); copyNote = nil }
    }

    private func addReply(_ source: String) {
        guard let brief = model.selected else { return }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let heading = "## Previous reply"
        let current = brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBody = current.isEmpty ? heading + "\n" + text : current + "\n\n" + heading + "\n" + text
        model.setBody(newBody, briefID: brief.id)
    }
}
#endif
