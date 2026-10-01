import Foundation

/// One list entry. `number` is its position among the ordered siblings around it (1, 2, 3 …),
/// whatever the source text said, so a list never shows 1. 1. 1. or restarts after a sub-list.
public struct MarkdownListItem: Equatable, Sendable {
    public var ordered: Bool
    public var number: Int
    public var text: String
    public var children: [MarkdownListItem]

    public init(ordered: Bool, number: Int = 0, text: String, children: [MarkdownListItem] = []) {
        self.ordered = ordered; self.number = number; self.text = text; self.children = children
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case list(items: [MarkdownListItem])
    case code(language: String, text: String)
    case quote(text: String)
    case rule
    case paragraph(text: String)
}

public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                blocks.append(.code(language: language, text: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                continue
            }

            if let heading = Self.heading(trimmed) {
                blocks.append(heading)
                i += 1
                continue
            }

            if Self.isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            if let quoted = Self.quoteLine(trimmed) {
                var quoteLines: [String] = []
                while i < lines.count, let q = Self.quoteLine(lines[i].trimmingCharacters(in: .whitespaces)) {
                    quoteLines.append(q)
                    i += 1
                }
                blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            if Self.listItem(line) != nil {
                blocks.append(.list(items: Self.parseList(lines, &i)))
                continue
            }

            var paragraphLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || Self.isBlockStart(t) { break }
                paragraphLines.append(l)
                i += 1
            }
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(text: paragraphLines.joined(separator: "\n")))
            }
        }

        return blocks
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        var count = 0
        for c in trimmed {
            if c == "#" { count += 1 } else { break }
        }
        guard count > 0, count <= 6 else { return nil }
        let rest = trimmed.dropFirst(count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return .heading(level: count, text: String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed)
        return chars.count == 1 && (chars.first == "-" || chars.first == "*" || chars.first == "_")
    }

    private static func quoteLine(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        let after = trimmed.dropFirst()
        if after.first == " " { return String(after.dropFirst()) }
        return String(after)
    }

    private struct RawItem { var indent: Int; var ordered: Bool; var number: Int; var text: String }

    private static func indentWidth(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func listItem(_ line: String) -> RawItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !isRule(trimmed) else { return nil }
        let indent = indentWidth(line)
        for marker in ["- ", "* ", "• ", "+ "] where trimmed.hasPrefix(marker) {
            return RawItem(indent: indent, ordered: false, number: 0,
                           text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
        return RawItem(indent: indent, ordered: true, number: number,
                       text: String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    /// Reads one list starting at `i`, keeping sub-lists nested, indented continuation lines with
    /// their item, and blank lines between items inside the same list.
    private static func parseList(_ lines: [String], _ i: inout Int) -> [MarkdownListItem] {
        var raws: [RawItem] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count, !raws.isEmpty else { break }
                let next = lines[j]
                let continues = listItem(next).map { $0.indent > raws[0].indent || $0.ordered == raws[0].ordered } ??
                    (indentWidth(next) > raws[0].indent && !isBlockStart(next.trimmingCharacters(in: .whitespaces)))
                guard continues else { break }
                i = j
                continue
            }
            if let item = listItem(line) {
                if let first = raws.first, item.indent <= first.indent, item.ordered != first.ordered { break }
                var clamped = item
                if let first = raws.first { clamped.indent = max(item.indent, first.indent) }
                raws.append(clamped)
                i += 1
            } else if !raws.isEmpty, !isBlockStart(trimmed) {
                raws[raws.count - 1].text += "\n" + trimmed
                i += 1
            } else {
                break
            }
        }
        return nest(raws[...])
    }

    private static func nest(_ raws: ArraySlice<RawItem>) -> [MarkdownListItem] {
        guard let base = raws.first?.indent else { return [] }
        var items: [MarkdownListItem] = []
        var idx = raws.startIndex
        while idx < raws.endIndex {
            let raw = raws[idx]
            var end = idx + 1
            while end < raws.endIndex, raws[end].indent > base { end += 1 }
            var item = MarkdownListItem(ordered: raw.ordered, text: raw.text,
                                        children: nest(raws[(idx + 1)..<end]))
            if raw.ordered {
                if let prev = items.last, prev.ordered { item.number = prev.number + 1 } else { item.number = max(raw.number, 1) }
            }
            items.append(item)
            idx = end
        }
        return items
    }

    private static func isBlockStart(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") { return true }
        if heading(trimmed) != nil { return true }
        if isRule(trimmed) { return true }
        if listItem(trimmed) != nil { return true }
        return false
    }
}
