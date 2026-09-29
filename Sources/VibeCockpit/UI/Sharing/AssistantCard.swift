#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Settings card: Kokoro's personality, what she calls you, and which model rewrites your prompts.
struct AssistantCard: View {
    @Environment(AppServices.self) private var services
    // Same keys as `AppServices.personaKey` / `addressNameKey`.
    @AppStorage("kokoroPersonaEnabled") private var persona = true
    @AppStorage("kokoroAddressName") private var addressName = ""
    @State private var pin: ProviderID?

    private var studio: PromptStudioModel { services.promptStudio }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Kokoro", systemImage: "sparkles")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                Toggle("Friendly personality", isOn: $persona)
                HStack {
                    Text("Call me").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                    TextField("Nothing in particular", text: $addressName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!persona)
                }
                Text("Changes apply to new conversations. With the personality off, replies are plain and code is never affected either way.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                MTDivider()
                HStack {
                    Text("Improve my prompts with").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                    Spacer()
                    Picker("", selection: Binding(get: { pin }, set: { pin = $0; studio.optimizerPin = $0 })) {
                        Text("The model I'm chatting with").tag(ProviderID?.none)
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
