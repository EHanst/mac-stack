#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI

/// Improve, in place: takes over the brief editor's box inside `BriefPane` and nothing else, so the
/// rest of the screen (target, meter, attachments, input bar) stays where it was. The model holds
/// the working revision; instructions typed in the input bar edit it through `BriefImproveModel`.
struct ImproveInlineView: View {
    @Environment(AppServices.self) private var services
    let brief: Brief

    @State private var tab = Tab.result
    @State private var acceptedChanges: Set<Int> = []
    @State private var cachedChanges: [WordDiff.Change] = []
    @AppStorage(DefaultsKey.briefViewMode) private var viewModeStorage: String = BriefViewMode.human.rawValue

    private enum Tab: String, CaseIterable {
        case result = "Result"
        case changes = "Changes"
        case edit = "Edit"
    }

    private var improve: BriefImproveModel { services.improve }
    private var studio: PromptStudioModel { services.promptStudio }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow.frame(height: 28)
            VStack(alignment: .leading, spacing: 8) {
                notice
                if isRunning || tab == .result {
                    resultScroll
                } else {
                    revisionBox
                }
            }
            .padding(10)
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(Color.mtSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onChange(of: studio.phase) { _, phase in improve.receiveOptimizerPhase(phase) }
        .onAppear {
            improve.receiveOptimizerPhase(studio.phase)
            resetAccepted()
        }
        .onChange(of: improve.revision) { _, _ in resetAccepted() }
    }

    // MARK: Top row and notices

    private var topRow: some View {
        HStack {
            if isRunning {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                if case .repairing(_, let missing) = improve.optimizerPhase {
                    Text("Restoring omitted terms…").font(.mtBodySmall)
                    if !missing.isEmpty {
                        Text(missing.prefix(3).joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                    }
                } else {
                    Text("Improving…").font(.mtBodySmall)
                    Text("A model on this Mac can take a little while.")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                Spacer()
                Button { improve.cancelOptimize(studio: studio) } label: { HotkeyLabel(title: "Cancel", hotkey: .cancel) }
                    .buttonStyle(MTTextButtonStyle()).hotkey(.cancel)
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if tab == .result {
                    // The same Human / Machine / JSON choice as the brief itself, applied to the rewrite.
                    Picker("View", selection: $viewModeStorage) {
                        ForEach(BriefViewMode.allCases, id: \.self) { Text("\($0.label)  \(Self.hotkey(for: $0).glyph)").tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .background {
                        ForEach(BriefViewMode.allCases, id: \.self) { mode in
                            Button("") { viewModeStorage = mode.rawValue }.hotkey(Self.hotkey(for: mode)).hidden()
                        }
                    }
                }
                if let id = studio.modelID {
                    Text("Improved by \(Self.modelLabel(id))")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        switch improve.optimizerPhase {
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.mtBodyMedium).foregroundStyle(Color.mtError)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { improve.dismissNotice(studio: studio) }
                    .buttonStyle(MTTextButtonStyle())
                    .controlSize(.small)
            }
        case .review(let result):
            VStack(alignment: .leading, spacing: 4) {
                if let rejection = result.rejection {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(rejection.reason, systemImage: "hand.raised.fill")
                                .font(.mtBodyMedium).fixedSize(horizontal: false, vertical: true)
                            if !rejection.missing.isEmpty {
                                Text("Dropped: " + rejection.missing.prefix(6).joined(separator: ", "))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                            }
                        }
                        Spacer()
                        Button("Dismiss") { improve.dismissNotice(studio: studio) }
                            .buttonStyle(MTTextButtonStyle())
                            .controlSize(.small)
                    }
                } else if !result.didChange && result.questions.isEmpty {
                    Label("That already reads clearly. Nothing to change.", systemImage: "checkmark.circle")
                        .font(.mtBodyMedium).foregroundStyle(Color.mtHealthy)
                }
                if !result.questions.isEmpty {
                    Text("A little more detail would help:").font(.mtLabelLarge)
                    ForEach(result.questions, id: \.self) { Text("• \($0)").font(.mtBodyMedium) }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Boxes

    /// One ScrollView for both the streaming text and the finished Result, so the user's scroll
    /// position survives the swap instead of snapping to the top when the rewrite lands.
    private var resultScroll: some View {
        ScrollView {
            Group {
                switch improve.optimizerPhase {
                case .running(let partial), .repairing(let partial, _):
                    // Until the first words arrive, keep showing the text being improved so nothing blanks out.
                    if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        streamingText(improve.revision)
                    } else {
                        streamingText(partial)
                    }
                default:
                    revisionView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func hotkey(for mode: BriefViewMode) -> Hotkey {
        switch mode { case .human: .viewHuman; case .machine: .viewMachine; case .json: .viewJSON }
    }

    /// The rewrite in the chosen form, compiled the same way the brief is when copied.
    @ViewBuilder
    private var revisionView: some View {
        let mode = BriefViewMode.from(stored: viewModeStorage)
        if mode == .human {
            MarkdownText(text: improve.revision)
        } else {
            var preview = brief
            let _ = preview.body = improve.revision
            let compiled = BriefCompiler.compile(preview, form: mode == .json ? .json : .compact)
            Text(compiled.text).font(AppTypography.monoFont(size: 13)).textSelection(.enabled)
        }
    }

    private func streamingText(_ text: String) -> some View {
        Text(text).font(.mtBodyMedium).lineSpacing(3)
    }

    @ViewBuilder
    private var revisionBox: some View {
        switch tab {
        case .result:
            EmptyView()
        case .changes:
            changesList
        case .edit:
            TextEditor(text: Binding(get: { improve.revision }, set: { improve.setRevision($0) }))
                .font(.mtBodyMedium)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: Changes

    private var changes: [WordDiff.Change] {
        cachedChanges
    }

    @ViewBuilder
    private var changesList: some View {
        let list = changes
        if list.isEmpty {
            Text("No differences from the previous text.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(list.count) \(list.count == 1 ? "change" : "changes"), \(acceptedChanges.count) kept")
                        .font(.mtLabelLarge)
                    Text("Untick any you don't want, then apply.")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    Spacer()
                    Button { acceptedChanges = Set(list.map(\.id)) } label: { Text("Keep all") }
                        .buttonStyle(MTTextButtonStyle())
                    Button { acceptedChanges = [] } label: { Text("Drop all") }
                        .buttonStyle(MTTextButtonStyle())
                    Button { applyAccepted() } label: { Text("Apply") }
                        .buttonStyle(MTOutlinedButtonStyle())
                        .disabled(acceptedChanges.count == list.count)
                        .help("Rewrite the result to keep only the ticked changes")
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Changes")
                            .font(.mtLabelSmall)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { index, change in
                                    if let section = change.section, index == 0 || list[index - 1].section != section {
                                        Text(section.uppercased()).font(.mtLabelLarge)
                                            .padding(.top, index == 0 ? 0 : 6)
                                    }
                                    changeCard(change)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    MTVerticalDivider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Whole brief")
                            .font(.mtLabelSmall)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                        ScrollView {
                            Text(fullTextDiff)
                                .font(.mtBodyMedium).lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func changeCard(_ change: WordDiff.Change) -> some View {
        let kept = acceptedChanges.contains(change.id)
        let title: String = switch change.kind {
        case .added: "Added"
        case .removed: "Removed"
        case .reworded: "Reworded"
        }
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { kept },
                set: { on in if on { acceptedChanges.insert(change.id) } else { acceptedChanges.remove(change.id) } }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .help(kept ? "Keeping this change" : "Dropping this change")
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                if !change.lead.isEmpty { contextLine("…" + change.lead) }
                if !change.before.isEmpty { diffLine("−", change.before, Color.mtError) }
                if !change.after.isEmpty { diffLine("+", change.after, Color.mtHealthy) }
                if !change.trail.isEmpty { contextLine(change.trail + "…") }
                Text("Likely: " + change.reason.lowercased())
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                if !change.lostLiterals.isEmpty {
                    Label("Drops " + change.lostLiterals.prefix(4).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.mtBodySmall).foregroundStyle(Color.mtError)
                }
            }
            .opacity(kept ? 1 : 0.45)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mtSurfaceContainerHigh.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func contextLine(_ text: String) -> some View {
        Text(text).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant).lineLimit(2)
    }

    private func diffLine(_ sign: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign).font(.mtBodyMedium.weight(.bold)).foregroundStyle(tint)
            Text(text).font(.mtBodyMedium).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The whole revision with removals struck through in red and additions highlighted in green.
    private var fullTextDiff: AttributedString {
        var out = AttributedString()
        for segment in WordDiff.segments(from: improve.originalText, to: improve.revision) {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same: break
            case .added:
                piece.foregroundColor = Color.mtHealthy
                piece.backgroundColor = Color.mtHealthy.opacity(0.14)
            case .removed:
                piece.foregroundColor = Color.mtError
                piece.strikethroughStyle = .single
            }
            out += piece
        }
        return out
    }

    private func applyAccepted() {
        let merged = WordDiff.merge(original: improve.originalText, proposed: improve.revision,
                                    acceptedHunkIndexes: acceptedChanges)
        improve.setRevision(merged)
    }

    private func resetAccepted() {
        let diffs = WordDiff.changes(from: improve.originalText, to: improve.revision)
        cachedChanges = diffs
        acceptedChanges = Set(diffs.map(\.id))
    }

    private var isRunning: Bool {
        switch improve.optimizerPhase {
        case .running, .repairing: return true
        default: return false
        }
    }

    private static func modelLabel(_ id: String) -> String {
        id.hasPrefix("local:") ? String(id.dropFirst(6)) + " (on this Mac)" : id + " (cloud)"
    }
}

/// The Improve buttons, shown in the slot where Copy and Save normally sit.
struct ImproveActionBar: View {
    @Environment(AppServices.self) private var services
    private var improve: BriefImproveModel { services.improve }
    private var studio: PromptStudioModel { services.promptStudio }
    @State private var copied = false

    @AppStorage(DefaultsKey.briefViewMode) private var viewModeStorage: String = BriefViewMode.human.rawValue

    private var isRunning: Bool {
        switch improve.optimizerPhase {
        case .running, .repairing: return true
        default: return false
        }
    }

    /// The rewrite in the form chosen in the view picker, redacted like every other copy.
    private func copyText() -> String {
        guard var brief = services.briefs.selected else { return ContextRedactor.redact(improve.revision).text }
        brief.body = improve.revision
        let form: BriefCompiler.Form = switch BriefViewMode.from(stored: viewModeStorage) {
        case .human: .readable
        case .machine: .compact
        case .json: .json
        }
        return BriefCompiler.compile(brief, form: form).text
    }

    var body: some View {
        HStack {
            if !isRunning {
                let empty = improve.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { improve.keepMine() } label: { HotkeyLabel(title: "Discard rewrite", hotkey: .cancel) }
                    .buttonStyle(MTTextButtonStyle()).hotkey(.cancel)
                    .help("Throw away this rewrite and go back to your brief, exactly as it was. Nothing is saved.")
                Button { improve.improve(studio: studio) } label: { HotkeyLabel(title: "Improve", hotkey: .improve) }
                    .buttonStyle(MTOutlinedButtonStyle()).hotkey(.improve)
                    .help("Run an improve pass on this draft")
                    .disabled(empty)
                Button { improve.expand(studio: studio) } label: { Text("Expand") }
                    .buttonStyle(MTOutlinedButtonStyle())
                    .help("Try again and turn this into a detailed specification")
                    .disabled(empty)
                Button { improve.expand(studio: studio, finer: true) } label: { Text("Finer") }
                    .buttonStyle(MTOutlinedButtonStyle())
                    .help("Split the current steps one level finer")
                    .disabled(empty)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText(), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: { HotkeyLabel(title: copied ? "Copied" : "Copy", systemImage: "doc.on.doc", hotkey: .copyMachine) }
                .hotkey(.copyMachine)
                .help("Copy this improved prompt without saving it")
                .disabled(empty)
                Button { improve.acceptAndContinue(studio: studio) } label: { Text("Save and improve again") }
                    .buttonStyle(MTOutlinedButtonStyle())
                    .help("Save this version to the brief, then run another improve pass on it")
                Button { improve.accept() } label: { HotkeyLabel(title: "Save", hotkey: .save) }
                    .buttonStyle(MTFilledButtonStyle())
                    .help("Save this version as the brief and close")
                    .hotkey(.save)
                    .disabled(empty)
            } else {
                Spacer()
            }
        }
    }
}
#endif
