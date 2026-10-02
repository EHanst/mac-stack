#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI
import AppKit

/// Right column: the editable brief (linked to the input or hand-edited) plus its attachments, with target, Improve, and Copy.
/// The model receives the compiled text (brief plus attachments), not this editor's raw contents.
struct BriefPane: View {
    @Environment(AppServices.self) private var services
    private enum CopyKind: String { case machine, standard, json, jsonMinified }
    @State private var copied: CopyKind?
    @AppStorage(DefaultsKey.briefViewMode) private var viewModeStorage: String = BriefViewMode.human.rawValue
    @AppStorage(DefaultsKey.briefLastCopy) private var lastCopyStorage: String = CopyKind.machine.rawValue
    @State private var showVersions = false
    @State private var editingHuman = false
    @State private var exportRoots: [URL] = []
    @State private var exportMessage: String?
    @State private var copyNote: String?
    @State private var originalExpanded = false

    private var model: BriefWorkbenchModel { services.briefs }
    private var improve: BriefImproveModel { services.improve }

    /// The format copied last time: it gets the filled button once the brief has been improved.
    private var lastCopy: CopyKind { CopyKind(rawValue: lastCopyStorage) ?? .machine }

    private var viewMode: BriefViewMode {
        get { BriefViewMode.from(stored: viewModeStorage) }
        nonmutating set { viewModeStorage = newValue.rawValue }
    }

    var body: some View {
        if let brief = model.selected, let compiled = model.compiled {
            VStack(alignment: .leading, spacing: 12) {
                targetPicker(brief)
                meter(brief, compiled)
                let improving = improve.presentedBriefID == brief.id
                if improving {
                    ImproveInlineView(brief: brief)
                } else {
                    originalDraft(brief)
                    editor(brief, compiled: compiled)
                }
                statusLine(brief, compiled)
                // Same slot either way: Copy and Save while editing, Save and Discard rewrite while improving.
                Group {
                    if improving { ImproveActionBar() } else { copyBar }
                }
                .frame(minHeight: 30)
            }
            .padding(16)
            .sheet(isPresented: $showVersions) {
                BriefVersionsSheet(brief: brief, onRestore: { model.restoreVersion($0) }, onClose: { showVersions = false })
            }
            .task(id: model.selectedID) { editingHuman = false; exportMessage = nil; exportRoots = await model.exportRoots() }
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

    /// Improve is the main step until the brief has been improved; after that Copy takes over.
    @ViewBuilder
    private func improveButton(_ brief: Brief, empty: Bool) -> some View {
        let button = Button { improve.open(brief, studio: services.promptStudio) } label: { HotkeyLabel(title: "Improve", hotkey: .improve) }
            .disabled(empty)
            .hotkey(.improve)
        if brief.isEdited { button.buttonStyle(MTOutlinedButtonStyle()) } else { button.buttonStyle(MTFilledButtonStyle()) }
    }

    /// The first thing typed, kept in view for reference once the brief has been rewritten.
    /// Three lines by default; click to show it all.
    @ViewBuilder
    private func originalDraft(_ brief: Brief) -> some View {
        let draft = brief.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if brief.body != nil, !draft.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button { originalExpanded.toggle() } label: {
                    Label("Original draft", systemImage: originalExpanded ? "chevron.down" : "chevron.right")
                        .font(.mtLabelSmall)
                }
                .buttonStyle(.plain).foregroundStyle(Color.mtOnSurfaceVariant)
                if originalExpanded {
                    ScrollView {
                        Text(draft).font(.mtBodySmall).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } else {
                    Text(draft).font(.mtBodySmall).lineLimit(3).foregroundStyle(Color.mtOnSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color.mtSurfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func editor(_ brief: Brief, compiled: CompiledPrompt) -> some View {
        let empty = brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("View", selection: Binding(
                    get: { viewMode },
                    set: { viewMode = $0 }
                )) {
                    ForEach(BriefViewMode.allCases, id: \.self) { Text("\($0.label)  \(Self.hotkey(for: $0).glyph)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .background {
                    // Segments cannot carry shortcuts themselves, so hidden buttons do.
                    ForEach(BriefViewMode.allCases, id: \.self) { mode in
                        Button("") { viewMode = mode }.hotkey(Self.hotkey(for: mode)).hidden()
                    }
                }
                if viewMode == .machine {
                    let compact = BriefCompiler.compile(brief, compact: true)
                    let savings = TokenSavings.percent(plain: compiled.tokens, compact: compact.tokens)
                    Text("\(BriefViewMode.machineCaption(for: brief.target)) · ~\(compact.tokens) tokens (saves \(savings)%)")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                } else if viewMode == .json {
                    let json = BriefCompiler.compile(brief, form: .json)
                    Text("For programs that parse the brief · ~\(json.tokens) tokens")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                } else {
                    Toggle(isOn: $editingHuman) { HotkeyLabel(title: "Edit", hotkey: .edit) }
                        .toggleStyle(.button).controlSize(.small).hotkey(.edit)
                }
                Spacer()
                Button { model.restoreVersion(brief.versions.count - 1) } label: { Text("Revert") }
                    .buttonStyle(MTTextButtonStyle())
                    .disabled(!brief.isEdited || brief.versions.isEmpty)
                    .help("Put back the previous version. What you have now is saved first, so this can be undone.")
                improveButton(brief, empty: empty)
            }
            .frame(height: 28)
            Group {
                if viewMode == .json {
                    ScrollView {
                        Text(empty ? "Nothing to show yet." : BriefCompiler.compile(brief, form: .json).text)
                            .font(AppTypography.monoFont(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if viewMode == .machine {
                    let compact = BriefCompiler.compile(brief, compact: true)
                    ScrollView {
                        Text(empty ? "Nothing to show yet." : compact.text)
                            .font(AppTypography.monoFont(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if editingHuman {
                    EchoGuardedEditor(external: brief.effectiveBody) { model.setBody($0) }
                        .id("\(brief.id)-body")
                        .font(.mtBodyMedium)
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView {
                        if empty {
                            Text("Nothing to show yet.").font(.mtBodyMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownText(text: brief.effectiveBody)
                        }
                    }
                }
            }
            .padding(10)
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(Color.mtSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// One reserved line for attachments, warnings and the last copy or save result, so none of
    /// them ever moves the brief. Attachments are managed from the paperclip.
    private func statusLine(_ brief: Brief, _ compiled: CompiledPrompt) -> some View {
        let included = brief.contextItems.filter(\.included)
        let attachments = included.isEmpty ? nil
            : "\(included.count) attachment\(included.count == 1 ? "" : "s"), about \(included.reduce(0) { $0 + $1.tokens }.formatted()) tokens"
        let warning = compiled.warnings.first?.message
        let text = BriefStatusLine.text(note: copyNote, export: exportMessage, warning: warning, attachments: attachments)
        return Label {
            Text(text).lineLimit(1).truncationMode(.tail)
        } icon: {
            if copyNote == nil && exportMessage == nil && warning != nil {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .help(compiled.warnings.map(\.message).joined(separator: "\n"))
    }

    private func targetPicker(_ brief: Brief) -> some View {
        HStack(spacing: 16) {
            Picker("Target model", selection: Binding(get: { brief.target.modelFamily },
                                                      set: { model.setTarget(modelFamily: $0) })) {
                Text("Claude").tag("claude"); Text("GPT").tag("gpt"); Text("Gemini").tag("gemini"); Text("Reasoning").tag("reasoning"); Text("Local").tag("local"); Text("Other").tag("generic")
            }
            Spacer()
        }
        .font(.mtBodyMedium)
        .pickerStyle(.menu)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// " · draft was 640 (+62)" once Improve has changed the text, so its cost is visible.
    private static func draftNote(_ brief: Brief, now: Int) -> String {
        guard let draft = BriefCompiler.draftTokens(brief) else { return "" }
        let delta = now - draft
        return " · draft was \(draft.formatted()) (\(delta >= 0 ? "+" : "−")\(abs(delta).formatted()))"
    }

    private func meter(_ brief: Brief, _ compiled: CompiledPrompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(Double(compiled.tokens), Double(brief.target.tokenBudget)),
                         total: Double(max(brief.target.tokenBudget, 1)))
            Text("About \(compiled.tokens.formatted()) of \(brief.target.tokenBudget.formatted()) tokens\(Self.draftNote(brief, now: compiled.tokens))")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private var copyBar: some View {
        let empty = !model.canCopy
        let primary = model.selected?.isEdited == true ? lastCopy : nil
        return HStack {
            copyButton(.machine, primary: primary, empty: empty, title: "Copy for machine", icon: "cpu",
                       help: "Compact, data-dense text that uses fewer tokens", hotkey: .copyMachine)
            if viewMode == .json {
                copyButton(.json, primary: primary, empty: empty, title: "Copy JSON", icon: "curlybraces",
                           help: "Pretty-printed JSON", hotkey: nil)
                copyButton(.jsonMinified, primary: primary, empty: empty, title: "Minified", icon: "arrow.down.right.and.arrow.up.left",
                           help: "The same JSON on one line, for pipelines", hotkey: nil)
            }
            copyButton(.standard, primary: primary, empty: empty, title: "Copy", icon: "doc.on.doc", help: "Readable text", hotkey: .copyReadable)
            Menu("Save to project") {
                ForEach(Array(exportRoots.enumerated()), id: \.element) { index, root in
                    let save = Button(root.lastPathComponent) { exportMessage = model.exportSelected(to: root) }
                    if index == 0 { save.hotkey(.save) } else { save }
                }
                if !exportRoots.isEmpty { Divider() }
                let add = Button("Add folder…") { addFolderAndSave() }
                if exportRoots.isEmpty { add.hotkey(.save) } else { add }
            }
            .help("Save to the first project (\(Hotkey.save.glyph))")
            .disabled(empty)
            .onHover { if $0 { Task { exportRoots = await model.exportRoots() } } }
            Button { showVersions = true } label: { Text("Versions") }
                .buttonStyle(MTOutlinedButtonStyle())
                .disabled(model.selected?.versions.isEmpty ?? true)
        }
    }

    @ViewBuilder
    private func copyButton(_ kind: CopyKind, primary: CopyKind?, empty: Bool, title: String, icon: String, help: String, hotkey: Hotkey?) -> some View {
        let button = Button { copy(kind) } label: {
            if let hotkey {
                HotkeyLabel(title: copied == kind ? "Copied" : title, systemImage: icon, hotkey: hotkey)
            } else {
                Label(copied == kind ? "Copied" : title, systemImage: icon)
            }
        }
        .help(help)
        .disabled(empty)
        .background { if let hotkey { Button("") { copy(kind) }.hotkey(hotkey).hidden().disabled(empty) } }
        if primary == kind { button.buttonStyle(MTFilledButtonStyle()) } else { button.buttonStyle(MTOutlinedButtonStyle()) }
    }

    /// Adds a folder as a project, then saves the brief into it.
    private func addFolderAndSave() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add and save"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            await services.workspacesModel.add(folder)
            exportRoots = await model.exportRoots()
            if let error = services.workspacesModel.lastError {
                exportMessage = error
            } else {
                exportMessage = model.exportSelected(to: folder)
            }
        }
    }

    private static func hotkey(for mode: BriefViewMode) -> Hotkey {
        switch mode { case .human: .viewHuman; case .machine: .viewMachine; case .json: .viewJSON }
    }

    private func copy(_ kind: CopyKind) {
        guard let brief = model.selected else { return }
        let form: BriefCompiler.Form = switch kind {
        case .machine: .compact
        case .standard: .readable
        case .json: .json
        case .jsonMinified: .jsonMinified
        }
        let compiledForCopy = BriefCompiler.compile(brief, form: form)
        let text = model.copyForClipboard(for: nil, form: form)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        lastCopyStorage = kind.rawValue
        let secretWord = compiledForCopy.redactedCount == 1 ? "secret" : "secrets"
        let what = switch kind {
        case .machine: "Copied for machine"
        case .standard: "Copied"
        case .json: "Copied JSON"
        case .jsonMinified: "Copied minified JSON"
        }
        copyNote = "\(what), ~\(compiledForCopy.tokens) tokens, \(compiledForCopy.redactedCount) \(secretWord) redacted"
        Task { try? await Task.sleep(for: .seconds(2)); copyNote = nil }
    }
}
#endif
