#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI

/// A single-line instruction field at the bottom of the Brief pane. Sends a plain-language edit to the
/// feedback model, with an Undo button and progress/error display.
struct BriefFeedbackBar: View {
    @Environment(AppServices.self) private var services
    let brief: Brief

    @State private var instruction = ""
    private var feedback: BriefFeedbackModel { services.feedback }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Edit with an instruction, e.g. “clarify the acceptance criteria”", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("Send") { send() }
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || feedback.phase == .editing)
                Button("Undo") { feedback.undo(briefID: brief.id) }
                    .disabled(!feedback.canUndo(briefID: brief.id))
            }
            if feedback.phase == .editing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Editing…").font(.mtBodySmall)
                }
            } else if case .failed(let message) = feedback.phase {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
        }
    }

    private func send() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        feedback.send(text, brief: brief)
        instruction = ""
    }
}
#endif
