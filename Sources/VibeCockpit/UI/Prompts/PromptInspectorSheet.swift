#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// "What the model sees": the system message and the exact text the next message would send.
struct PromptInspectorSheet: View {
    @Environment(AppServices.self) private var services
    let draft: String
    let intent: PromptEngineer.Intent?
    let onClose: () -> Void

    @State private var preview: AppServices.PromptPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("What the model sees", systemImage: "eye").font(.mtTitleMedium)
                Spacer()
                Button("Done", action: onClose).buttonStyle(MTFilledButtonStyle()).keyboardShortcut(.defaultAction)
            }
            MTDivider()
            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        block("System message", preview.system, note: "Set once when the conversation starts.")
                        block("Your next message, as sent", preview.userTurn,
                              note: "Guidance for “\(preview.intent)” tasks is added from your Prompts recipes"
                                + (preview.usedRetrievedCode ? ", plus code found in your project." : "."))
                        Text("About \(preview.estimatedTokens.formatted()) tokens in all, counting \(preview.earlierMessages) earlier message\(preview.earlierMessages == 1 ? "" : "s").")
                            .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
        .task { preview = await services.previewNextTurn(draft, intent: intent) }
    }

    private func block(_ title: String, _ text: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.mtLabelLarge)
            Text(note).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            Text(text).font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
                .background(Color.mtSurfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
#endif
