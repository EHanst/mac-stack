#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
import StackCore
#endif
import SwiftUI

/// Shows brainstorming questions and tips for the selected brief. Tapping a question hands it to
/// `onPick`, which starts an instruction in the input bar. Refreshes after a 2s debounce when the
/// brief has been edited or improved, or on manual refresh.
struct BrainstormBanner: View {
    var onPick: (String) -> Void
    @Environment(AppServices.self) private var services
    private var feedback: BriefFeedbackModel { services.feedback }
    private var workbench: BriefWorkbenchModel { services.briefs }

    var body: some View {
        if let brief = workbench.selected {
            content(brief)
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
            .background(Color.mtSurfaceContainerHigh.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .task(id: brief.effectiveBody) {
                // Auto-refresh after 2s only for edited/improved briefs (body != nil).
                guard brief.body != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                feedback.refreshBrainstorm(brief: brief)
            }
        }
    }
}
#endif
