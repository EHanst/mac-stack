import Foundation

/// Makes every numbered list count 1, 2, 3 … at its own depth, whatever numbers the text came with.
/// Fenced code is left alone, and the text is otherwise unchanged.
public enum MarkdownNumbering {
    private struct Level { var indent: Int; var next: Int }

    public static func renumber(_ text: String) -> String {
        var levels: [Level] = []
        var inFence = false
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); out.append(raw); continue }
            if inFence || trimmed.isEmpty { out.append(raw); continue }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let item = orderedItem(trimmed) {
                while let top = levels.last, top.indent > indent { levels.removeLast() }
                if let top = levels.last, top.indent == indent {
                    levels[levels.count - 1].next += 1
                } else {
                    levels.append(Level(indent: indent, next: item.number))
                }
                let number = levels[levels.count - 1].next
                out.append(String(raw.prefix(while: { $0 == " " || $0 == "\t" })) + "\(number)\(item.delimiter) " + item.rest)
            } else if isBullet(trimmed) {
                while let top = levels.last, top.indent >= indent { levels.removeLast() }
                out.append(raw)
            } else {
                // Indented text continues the item above; anything else ends the list.
                if indent == 0 { levels.removeAll() } else { while let top = levels.last, top.indent >= indent { levels.removeLast() } }
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }

    private static func orderedItem(_ trimmed: String) -> (number: Int, delimiter: Character, rest: String)? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
        return (number, d, String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ trimmed: String) -> Bool {
        ["- ", "* ", "• ", "+ "].contains { trimmed.hasPrefix($0) }
    }
}
