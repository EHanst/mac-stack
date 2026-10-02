import Testing
@testable import StackCore

@Suite("Hotkey")
struct HotkeyTests {
    @Test("no two actions share a shortcut")
    func unique() {
        let glyphs = Hotkey.all.map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
    }

    @Test("glyphs follow the macOS order", arguments: [
        (Hotkey.improve, "⌘R"), (Hotkey.edit, "⇧⌘E"), (Hotkey.copyReadable, "⌥⌘C"), (Hotkey.send, "⌘↩"),
        (Hotkey.cancel, "⎋"),
    ])
    func glyph(hotkey: Hotkey, expected: String) { #expect(hotkey.glyph == expected) }
}
