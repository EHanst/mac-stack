#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
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
    @AppStorage("brief.viewMode") private var viewModeStorage: String = BriefViewMode.human.rawValue
    @State private var showVersions = false
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

    private func editor(_ brief: Brief, compiled: CompiledPrompt) -> some View {
        let empty = brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let compact = BriefCompiler.compile(brief, compact: true)
        let compactTokens = compact.tokens
        let savings = TokenSavings.percent(plain: compiled.tokens, compact: compactTokens)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brief").font(.mtLabelLarge)
                Picker("View", selection: Binding(
                    get: { viewMode },
                    set: { viewMode = $0 }
                )) {
                    ForEach(BriefViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("Machine copy ~\(compactTokens) tokens (saves \(savings)%)")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Spacer()
                Button("Improve") { improve.open(brief, studio: services.promptStudio) }
                    .disabled(empty)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            if viewMode == .machine {
                Text(BriefViewMode.machineCaption(for: brief.target))
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                ScrollView {
                    Text(empty ? "Nothing to show yet." : compact.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
            }
        }
    }

    private func targetPicker(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(get: { brief.target.modelFamily },
                                               set: { model.setTarget(modelFamily: $0, surface: brief.target.surface) })) {
                Text("Claude").tag("claude"); Text("GPT").tag("gpt"); Text("Gemini").tag("gemini"); Text("Reasoning").tag("reasoning"); Text("Local").tag("local"); Text("Other").tag("generic")
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
            Button { copy(compact: true) } label: {
                Label(copied == .machine ? "Copied" : "Copy for machine", systemImage: "cpu")
            }
            .buttonStyle(MTFilledButtonStyle())
            .help("Compact, data-dense text that uses fewer tokens")
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(empty)
            Button { copy() } label: { Label(copied == .standard ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .option])
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

    private func copy(compact: Bool = false) {
        guard let brief = model.selected else { return }
        let compiledForCopy = BriefCompiler.compile(brief, compact: compact)
        let text = model.copyForClipboard(for: nil, compact: compact)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = compact ? .machine : .standard
        let secretWord = compiledForCopy.redactedCount == 1 ? "secret" : "secrets"
        copyNote = "\(compact ? "Copied for machine" : "Copied"), ~\(compiledForCopy.tokens) tokens, \(compiledForCopy.redactedCount) \(secretWord) redacted"
        Task { try? await Task.sleep(for: .seconds(2)); copyNote = nil }
    }
}
#endif
