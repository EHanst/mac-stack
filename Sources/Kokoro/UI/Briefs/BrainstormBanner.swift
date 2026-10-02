#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI

/// Brainstorming questions and tips for the selected brief, shown in a popover from the top bar so
/// they never move the brief. Tapping a question hands it to `onPick`, which starts an instruction
/// in the input bar.
struct BrainstormBanner: View {
    var onPick: (String) -> Void
    @Environment(AppServices.self) private var services
    private var feedback: BriefFeedbackModel { services.feedback }
    private var workbench: BriefWorkbenchModel { services.briefs }

    var body: some View {
        if let brief = workbench.selected {
            content(brief)
                // Opening the popover always brainstorms the current text (a no-op when already done).
                .task { feedback.refreshBrainstorm(brief: brief) }
        }
    }

    @ViewBuilder
    private func content(_ brief: Brief) -> some View {
        if !feedback.questions.isEmpty || !feedback.tips.isEmpty || feedback.brainstormPhase == .running || feedback.brainstormPhase.isFailed {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Brainstorm").font(.mtLabelLarge)
                    Spacer()
                    if feedback.brainstormPhase == .running {
                        ProgressView().controlSize(.small)
                    }
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
                        onPick(q.text)
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
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No suggestions for this brief.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Button("Brainstorm again") { feedback.refreshBrainstorm(brief: brief, force: true) }
            }
            .padding(12)
        }
    }
}

/// Keeps brainstorming current without taking any space: always mounted, draws nothing.
struct BrainstormAutoRefresh: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        if let brief = services.briefs.selected {
            Color.clear.frame(width: 0, height: 0)
                .task(id: brief.effectiveBody) {
                    // Auto-refresh after 2s only for edited/improved briefs (body != nil).
                    guard brief.body != nil else { return }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    services.feedback.refreshBrainstorm(brief: brief)
                }
        }
    }
}
#endif
