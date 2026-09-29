#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Asks for the blanks in a saved prompt (`{{name}}`), then hands back the finished text.
struct InsertPromptSheet: View {
    let studio: PromptStudioModel
    let prompt: SavedPrompt
    let onInsert: (String) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(prompt.title, systemImage: "text.quote").font(.mtTitleMedium)
            MTDivider()
            ForEach(studio.fieldsToAsk(for: prompt), id: \.self) { name in
                VStack(alignment: .leading, spacing: 3) {
                    Text(name.replacingOccurrences(of: "_", with: " ")).font(.mtLabelMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                    TextField("", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...5)
                }
            }
            Text("Preview").font(.mtLabelMedium).foregroundStyle(Color.mtOnSurfaceVariant)
            ScrollView {
                Text(studio.text(for: prompt, values: values)).font(.mtBodySmall)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 130).padding(8)
            .background(Color.mtSurfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Cancel", action: onCancel).buttonStyle(MTTextButtonStyle())
                Spacer()
                Button("Insert") { onInsert(studio.text(for: prompt, values: values)) }
                    .buttonStyle(MTFilledButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
#endif
