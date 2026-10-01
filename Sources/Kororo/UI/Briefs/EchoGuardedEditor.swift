#if canImport(AppKit)
import SwiftUI

/// Keeps the text in local state while typing. Binding straight to the model made SwiftUI compare
/// against a stale snapshot mid-keystroke and reset the selection to the end.
struct EchoGuardedEditor: View {
    let external: String
    let onChange: (String) -> Void
    @State private var text: String
    @State private var lastSent: String

    init(external: String, onChange: @escaping (String) -> Void) {
        self.external = external
        self.onChange = onChange
        _text = State(initialValue: external)
        _lastSent = State(initialValue: external)
    }

    var body: some View {
        TextEditor(text: $text)
            .onChange(of: text) {
                guard text != lastSent else { return }
                lastSent = text
                onChange(text)
            }
            .onChange(of: external) {
                // Ignore the echo of our own edit; adopt real outside changes (Improve, Add, undo).
                guard external != lastSent, external != text else { return }
                lastSent = external
                text = external
            }
    }
}
#endif
