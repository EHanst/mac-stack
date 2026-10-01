#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
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
            questionsTipsStrip
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionRow
            chatInput
        }
        .padding(16)
        .background(Color.mtSurfaceContainerLowest)
        .onChange(of: studio.phase) { _, phase in improve.receiveOptimizerPhase(phase) }
        .onAppear { improve.receiveOptimizerPhase(studio.phase) }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Improving…").font(.mtBodySmall)
            }
            ScrollView {
                Text(partial.isEmpty ? " " : partial)
                    .font(.mtBodyMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            Text("A model on this Mac can take a little while. Your working revision stays as a draft.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            HStack {
                Spacer()
                Button("Cancel") { improve.cancelOptimize(studio: studio) }
                    .buttonStyle(MTTextButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    ScrollView {
                        Text(Self.diffAttributed(WordDiff.segments(from: originalText, to: improve.revision)))
                            .font(.mtBodyMedium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private var originalText: String { brief.effectiveBody }

    @ViewBuilder
    private var actionRow: some View {
        if isOptimizerRunning {
            EmptyView()
        } else {
            HStack {
                Button("Keep mine") { improve.keepMine() }.buttonStyle(MTTextButtonStyle())
                Button("Expand") { improve.expand(studio: studio) }.buttonStyle(MTOutlinedButtonStyle())
                    .help("Try again and turn this into a detailed specification")
                Spacer()
                Button("Accept and continue") { improve.acceptAndContinue(studio: studio) }.buttonStyle(MTOutlinedButtonStyle())
                Button("Accept") { improve.accept() }.buttonStyle(MTFilledButtonStyle())
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
