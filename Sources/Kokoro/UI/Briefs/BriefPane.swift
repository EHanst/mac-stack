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
    private enum CopyKind: String { case machine, standard, json }
    @State private var copied: CopyKind?
    @AppStorage(DefaultsKey.briefViewMode) private var viewModeStorage: String = BriefViewMode.human.rawValue
    @State private var showVersions = false
    @State private var editingHuman = false
    @State private var exportRoots: [URL] = []
    @State private var exportMessage: String?
    @State private var copyNote: String?

    private var model: BriefWorkbenchModel { services.briefs }
    private var improve: BriefImproveModel { services.improve }

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
                    editor(brief, compiled: compiled)
                }
                statusLine(brief, compiled)
                // Same slot either way: Copy and Save while editing, Save and Discard while improving.
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

    private func editor(_ brief: Brief, compiled: CompiledPrompt) -> some View {
        let empty = brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("View", selection: Binding(
                    get: { viewMode },
                    set: { viewMode = $0 }
                )) {
                    ForEach(BriefViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
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
                    Toggle("Edit", isOn: $editingHuman).toggleStyle(.button).controlSize(.small)
                }
                Spacer()
                Button("Improve") { improve.open(brief, studio: services.promptStudio) }
                    .disabled(empty)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
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
        let text = copyNote ?? exportMessage ?? warning ?? attachments ?? " "
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
                                                      set: { model.setTarget(modelFamily: $0, surface: brief.target.surface) })) {
                Text("Claude").tag("claude"); Text("GPT").tag("gpt"); Text("Gemini").tag("gemini"); Text("Reasoning").tag("reasoning"); Text("Local").tag("local"); Text("Other").tag("generic")
            }
            Picker("Where", selection: Binding(get: { brief.target.surface },
                                               set: { model.setTarget(modelFamily: brief.target.modelFamily, surface: $0) })) {
                ForEach(Surface.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Spacer()
        }
        .font(.mtBodyMedium)
        .pickerStyle(.menu)
        .fixedSize(horizontal: false, vertical: true)
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
            Button { copy(compact: true) } label: {
                Label(copied == .machine ? "Copied" : "Copy for machine", systemImage: "cpu")
            }
            .buttonStyle(MTFilledButtonStyle())
            .help("Compact, data-dense text that uses fewer tokens")
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(empty)
            if viewMode == .json {
                Button { copy(json: true) } label: {
                    Label(copied == .json ? "Copied" : "Copy JSON", systemImage: "curlybraces")
                }
                .disabled(empty)
            }
            Button { copy() } label: { Label(copied == .standard ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(empty)
            Menu("Save to project") {
                ForEach(exportRoots, id: \.self) { root in
                    Button(root.lastPathComponent) { exportMessage = model.exportSelected(to: root) }
                }
                if !exportRoots.isEmpty { Divider() }
                Button("Add folder…") { addFolderAndSave() }
            }
            .disabled(empty)
            .onHover { if $0 { Task { exportRoots = await model.exportRoots() } } }
            Button("Versions") { showVersions = true }
                .disabled(model.selected?.versions.isEmpty ?? true)
        }
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

    private func copy(compact: Bool = false, json: Bool = false) {
        guard let brief = model.selected else { return }
        let compiledForCopy = BriefCompiler.compile(brief, form: json ? .json : compact ? .compact : .readable)
        let text = model.copyForClipboard(for: nil, compact: compact, json: json)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = json ? .json : compact ? .machine : .standard
        let secretWord = compiledForCopy.redactedCount == 1 ? "secret" : "secrets"
        copyNote = "\(json ? "Copied JSON" : compact ? "Copied for machine" : "Copied"), ~\(compiledForCopy.tokens) tokens, \(compiledForCopy.redactedCount) \(secretWord) redacted"
        Task { try? await Task.sleep(for: .seconds(2)); copyNote = nil }
    }
}
#endif
