#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Settings card: Kokoro's personality and what she calls you.
struct AssistantCard: View {
    // Same keys as `AppServices.personaKey` / `addressNameKey`.
    @AppStorage("kokoroPersonaEnabled") private var persona = true
    @AppStorage("kokoroAddressName") private var addressName = ""

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
            }
        }
    }
}
#endif
