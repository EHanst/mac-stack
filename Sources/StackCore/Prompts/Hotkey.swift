import Foundation

/// Every keyboard shortcut in the Briefs screen, in one place so none collide and each button can show its own.
/// `key` is one character; return, delete and escape use their control characters.
public struct Hotkey: Equatable, Sendable {
    public let key: Character
    public let command: Bool, shift: Bool, option: Bool

    public init(_ key: Character, command: Bool = true, shift: Bool = false, option: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option
    }

    public static let returnKey: Character = "\r"
    public static let deleteKey: Character = "\u{7F}"
    public static let escapeKey: Character = "\u{1B}"

    /// macOS order: ⌃ ⌥ ⇧ ⌘, then the key.
    public var glyph: String {
        let name: String = switch key {
        case Self.returnKey: "↩"
        case Self.deleteKey: "⌫"
        case Self.escapeKey: "⎋"
        default: String(key).uppercased()
        }
        return (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + name
    }

    // Screen
    public static let startOver = Hotkey("n")
    public static let loadFile = Hotkey("o")
    public static let brainstorm = Hotkey("b")
    public static let send = Hotkey(returnKey)
    public static let viewHuman = Hotkey("1")
    public static let viewMachine = Hotkey("2")
    public static let viewJSON = Hotkey("3")
    public static let edit = Hotkey("e", shift: true)
    public static let improve = Hotkey("r")
    public static let copyMachine = Hotkey("c", shift: true)
    public static let copyReadable = Hotkey("c", option: true)
    public static let save = Hotkey("s")
    public static let cancel = Hotkey(escapeKey, command: false)

    /// `improve`, `copyMachine`, `save` and `cancel` are reused by the Improve bar, which replaces the
    /// buttons that own them.
    public static let all: [Hotkey] = [
        startOver, loadFile, brainstorm, send, viewHuman, viewMachine, viewJSON, edit, improve,
        copyMachine, copyReadable, save, cancel,
    ]
}
