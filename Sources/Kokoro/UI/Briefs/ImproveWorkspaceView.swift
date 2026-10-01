#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI

/// Full-pane working space for improving a brief over multiple rounds. The model holds the working
/// revision; this view displays it and sends the user's instructions back to the same sidecar edit
/// path BriefFeedbackModel uses.
struct ImproveWorkspaceView: View {
    @Environment(AppServices.self) private var services
    let brief: Brief

    @State private var tab = Tab.preview
    @State private var instruction = ""
    @State private var acceptedHunkIndexes: Set<Int> = []

    private enum Tab: String, CaseIterable {
        case preview = "Preview"
        case changes = "Changes"
        case edit = "Edit"
    }

    private var model: BriefWorkbenchModel { services.briefs }
    private var improve: BriefImproveModel { services.improve }
    private var feedback: BriefFeedbackModel { services.feedback }
    private var studio: PromptStudioModel { services.promptStudio }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            MTDivider()
            CappedScroll(maxHeight: 150) { questionsTipsStrip }
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionRow
            chatInput
        }
        .padding(16)
        .background(Color.mtSurfaceContainerLowest)
        .onChange(of: studio.phase) { _, phase in improve.receiveOptimizerPhase(phase) }
        .onAppear {
            improve.receiveOptimizerPhase(studio.phase)
            resetAcceptedHunks()
        }
        .onChange(of: improve.revision) { _ in resetAcceptedHunks() }
        .task(id: brief.effectiveBody) {
            guard brief.body != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            feedback.refreshBrainstorm(brief: brief)
        }
    }

    private var header: some View {
        HStack {
            Label("Improve", systemImage: "wand.and.stars")
                .font(.mtTitleMedium)
            if let model = studio.modelID.map(Self.modelLabel) {
                Text("for \(model)").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
            Button { improve.close() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .help("Close and keep the working revision as a draft")
        }
    }

    @ViewBuilder
    private var questionsTipsStrip: some View {
        if !feedback.questions.isEmpty || !feedback.tips.isEmpty || feedback.brainstormPhase == .running || feedback.brainstormPhase.isFailed {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("QUESTIONS & TIPS").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    Spacer()
                    if feedback.brainstormPhase == .running { ProgressView().controlSize(.small) }
                    Button {
                        feedback.refreshBrainstorm(brief: brief, force: true)
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(feedback.brainstormPhase == .running)
                    Button {
                        feedback.dismissBrainstorm()
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                }
                if case .failed(let message) = feedback.brainstormPhase {
                    Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
                }
                ForEach(feedback.questions) { q in
                    Button {
                        instruction = "Q: \(q.text) "
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "questionmark.circle")
                            Text(q.text).font(.mtBodyMedium).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(feedback.tips, id: \.self) { tip in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "lightbulb")
                        Text(tip).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(12)
            .background(Color.mtSurfaceContainerHigh.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        switch improve.optimizerPhase {
        case .running(let partial):
            runningView(partial)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.mtBodyMedium).foregroundStyle(Color.mtError)
                    .fixedSize(horizontal: false, vertical: true)
                revisionTabs
            }
        case .review(let result):
            VStack(alignment: .leading, spacing: 10) {
                if let rejection = result.rejection {
                    Label(rejection.reason, systemImage: "hand.raised.fill")
                        .font(.mtBodyMedium).foregroundStyle(Color.mtOnSurface)
                        .fixedSize(horizontal: false, vertical: true)
                    if !rejection.missing.isEmpty {
                        Text("Dropped: " + rejection.missing.prefix(6).joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                    }
                } else if !result.didChange && result.questions.isEmpty {
                    Label("That already reads clearly. Nothing to change.", systemImage: "checkmark.circle")
                        .font(.mtBodyMedium).foregroundStyle(Color.mtHealthy)
                }
                if !result.questions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A little more detail would help:").font(.mtLabelLarge)
                        ForEach(result.questions, id: \.self) { Text("• \($0)").font(.mtBodyMedium) }
                    }
                }
                revisionTabs
            }
        case .idle:
            revisionTabs
        }
    }

    private func runningView(_ partial: String) -> some View {
        // Until the first words arrive, keep showing the text being improved so nothing blanks out.
        let waiting = partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Improving…").font(.mtBodySmall)
                Text("A model on this Mac can take a little while. Your working revision stays as a draft.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { improve.cancelOptimize(studio: studio) }
                    .buttonStyle(MTTextButtonStyle())
            }
            ScrollView {
                MarkdownText(text: waiting ? improve.revision : partial)
                    .opacity(waiting ? 0.5 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.mtSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var revisionTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            Group {
                switch tab {
                case .preview:
                    ScrollView {
                        MarkdownText(text: improve.revision)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                case .changes:
                    changesEditor
                case .edit:
                    TextEditor(text: editBinding())
                        .font(.mtBodyMedium)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.mtSurfaceContainerHighest)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var originalText: String { improve.originalText }

    private var changesEditor: some View {
        let hunks = WordDiff.hunks(from: originalText, to: improve.revision)
        return VStack(alignment: .leading, spacing: 8) {
            if hunks.isEmpty {
                Text("No differences from the previous text.")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                            Toggle(isOn: hunkBinding(for: index)) {
                                Text(Self.diffAttributed(hunk.segments))
                                    .font(.mtBodyMedium)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                HStack {
                    Spacer()
                    Button("Apply accepted changes") { applyAcceptedHunks() }
                        .buttonStyle(MTOutlinedButtonStyle())
                        .disabled(acceptedHunkIndexes.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actionRow: some View {
        if isOptimizerRunning {
            EmptyView()
        } else {
            HStack {
                Button("Discard") { improve.keepMine() }.buttonStyle(MTTextButtonStyle())
                    .help("Close without saving. The brief stays exactly as it was.")
                Button("Expand") { improve.expand(studio: studio) }.buttonStyle(MTOutlinedButtonStyle())
                    .help("Try again and turn this into a detailed specification")
                Button("Finer") { improve.expand(studio: studio, finer: true) }.buttonStyle(MTOutlinedButtonStyle())
                    .help("Split the current steps one level finer")
                Spacer()
                Button("Save and improve again") { improve.acceptAndContinue(studio: studio) }.buttonStyle(MTOutlinedButtonStyle())
                    .help("Save this version to the brief, then run another improve pass on it")
                Button("Save") { improve.accept() }.buttonStyle(MTFilledButtonStyle())
                    .help("Save this version as the brief and close")
                    .keyboardShortcut(.defaultAction)
                    .disabled(improve.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var chatInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Instruct this revision, e.g. “add acceptance criteria”", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("Send") { send() }
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || improve.chatEditPhase == .editing
                              || isOptimizerRunning)
                Button("Undo") { improve.undoEdit() }
                    .disabled(!improve.canUndoEdit)
            }
            if improve.chatEditPhase == .editing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Editing…").font(.mtBodySmall)
                }
            } else if case .failed(let message) = improve.chatEditPhase {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
        }
    }

    private func send() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        improve.applyEdit(text)
        instruction = ""
    }

    private func editBinding() -> Binding<String> {
        Binding(
            get: { improve.revision },
            set: { improve.setRevision($0) }
        )
    }

    private var isOptimizerRunning: Bool {
        if case .running = improve.optimizerPhase { return true }
        return false
    }

    private func hunkBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { acceptedHunkIndexes.contains(index) },
            set: { on in
                if on { acceptedHunkIndexes.insert(index) } else { acceptedHunkIndexes.remove(index) }
            }
        )
    }

    private func applyAcceptedHunks() {
        let merged = WordDiff.merge(original: originalText, proposed: improve.revision,
                                    acceptedHunkIndexes: acceptedHunkIndexes)
        improve.setRevision(merged)
    }

    private func resetAcceptedHunks() {
        acceptedHunkIndexes = Set(WordDiff.hunks(from: originalText, to: improve.revision).map(\.id))
    }

    private static func diffAttributed(_ segments: [WordDiff.Segment]) -> AttributedString {
        var out = AttributedString()
        for s in segments {
            var part = AttributedString(s.text)
            switch s.kind {
            case .same:
                break
            case .added:
                part.backgroundColor = Color.mtHealthy.opacity(0.22)
            case .removed:
                part.backgroundColor = Color.mtError.opacity(0.18)
                part.strikethroughStyle = .single
                part.foregroundColor = Color.mtOnSurfaceVariant
            }
            out += part
        }
        return out
    }

    private static func modelLabel(_ id: String) -> String {
        id.hasPrefix("local:") ? String(id.dropFirst(6)) + " (on this Mac)" : id + " (cloud)"
    }
}
#endif
