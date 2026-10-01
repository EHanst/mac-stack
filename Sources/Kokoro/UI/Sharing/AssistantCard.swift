#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

/// Settings card: which model rewrites your prompts.
struct AssistantCard: View {
    @Environment(AppServices.self) private var services
    @State private var pin: ProviderID?

    private var studio: PromptStudioModel { services.promptStudio }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                MTCardTitle("Kokoro", icon: "sparkles", tint: .accent)
                MTDivider()
                HStack {
                    Text("Rewrite prompts with").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                    Spacer()
                    Picker("", selection: Binding(get: { pin }, set: { pin = $0; studio.optimizerPin = $0 })) {
                        Text("The default model").tag(ProviderID?.none)
                        ForEach(studio.choices, id: \.id) { m in
                            Text(m.isLocal ? "\(m.id.replacingOccurrences(of: "local:", with: "")) (on this Mac)" : "\(m.id) (cloud)")
                                .tag(Optional(m.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Your draft goes to this model when you press Improve. A cloud model sees it, so it follows your privacy setting and is listed in the cloud use log.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await studio.refreshModel()
            pin = studio.optimizerPin
        }
    }
}
#endif
