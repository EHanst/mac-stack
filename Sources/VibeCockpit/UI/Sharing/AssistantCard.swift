#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Settings card: Kokoro's personality (editable), what they call you, and which model rewrites your prompts.
struct AssistantCard: View {
    @Environment(AppServices.self) private var services
    // Same keys as `AppServices.personaKey` / `addressNameKey`.
    @AppStorage("kokoroPersonaEnabled") private var persona = true
    @AppStorage("kokoroAddressName") private var addressName = ""
    @AppStorage("kokoroPersonality") private var customPersonality = ""
    @State private var draft = ""
    @State private var pin: ProviderID?

    private var studio: PromptStudioModel { services.promptStudio }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                MTCardTitle("Kokoro", icon: "sparkles", tint: .accent)
                MTDivider()
                Toggle("Personality", isOn: $persona)
                HStack {
                    Text("Call me").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                    TextField("Nothing in particular", text: $addressName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!persona)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Personality").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                        Spacer()
                        Text("\(draft.count)/\(AppServices.personalityLimit)")
                            .font(.mtBodySmall)
                            .foregroundStyle(draft.count > AppServices.personalityLimit ? Color.mtDegraded : Color.mtOnSurfaceVariant)
                        Button("Reset to default") { draft = AppServices.defaultPersonality }
                            .disabled(draft == AppServices.defaultPersonality)
                    }
                    TextEditor(text: $draft)
                        .font(.mtBodySmall)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.mtOnSurfaceVariant.opacity(0.3)))
                        .disabled(!persona)
                    Text("Write how Kokoro should sound, or rename them. Only the first \(AppServices.personalityLimit) characters are used. Kokoro's rules for correctness, safety and keeping the personality out of your code always apply.")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: draft) { _, new in
                    // Storing nothing means "use the default", so a later default improvement reaches everyone who never edited it.
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    customPersonality = (trimmed.isEmpty || trimmed == AppServices.defaultPersonality.trimmingCharacters(in: .whitespacesAndNewlines)) ? "" : new
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
            draft = AppServices.effectivePersonality(customPersonality)
            await studio.refreshModel()
            pin = studio.optimizerPin
        }
    }
}
#endif
