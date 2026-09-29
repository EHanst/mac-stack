#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Saves text (what's in the chat box, or an earlier message) as a reusable prompt.
struct SavePromptSheet: View {
    let studio: PromptStudioModel
    let initialBody: String
    let onDone: () -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var slash = ""
    @State private var tags = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Save as a prompt", systemImage: "bookmark.fill").font(.mtTitleMedium)
            MTDivider()
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Shortcut, e.g. review (type /review in the chat box)", text: $slash).textFieldStyle(.roundedBorder)
                TextField("Tags, comma separated", text: $tags).textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $text)
                .font(.mtBodyMedium).scrollContentBackground(.hidden).padding(6)
                .frame(height: 140)
                .background(Color.mtSurfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 8))
            let blanks = PromptTemplate.variables(in: text)
            Text(blanks.isEmpty
                 ? "Tip: write {{name}} where something changes each time, and you'll be asked for it when you use the prompt."
                 : "Blanks: " + blanks.map { "{{\($0)}}" }.joined(separator: "  "))
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.mtBodySmall).foregroundStyle(Color.mtError) }
            HStack {
                Button("Cancel", action: onDone).buttonStyle(MTTextButtonStyle())
                Spacer()
                Button("Save") { save() }.buttonStyle(MTFilledButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            text = initialBody
            title = Self.suggestedTitle(initialBody)
        }
    }

    private func save() {
        let clean = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let prompt = SavedPrompt(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? Self.suggestedTitle(text) : title,
            body: text.trimmingCharacters(in: .whitespacesAndNewlines), tags: clean, slash: slash.isEmpty ? nil : slash)
        Task {
            do { _ = try await studio.save(prompt); onDone() }
            catch { self.error = error.localizedDescription }
        }
    }

    static func suggestedTitle(_ body: String) -> String {
        let first = body.split(separator: "\n").first.map(String.init) ?? "Untitled"
        return first.count > 48 ? String(first.prefix(48)) + "…" : first
    }
}
#endif
