import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(items: [String])
    case numbered(items: [String])
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

            if let item = Self.bulletItem(trimmed) {
                var items: [String] = []
                while i < lines.count, let itemLine = Self.bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(itemLine)
                    i += 1
                }
                blocks.append(.bullet(items: items))
                continue
            }

            if let item = Self.numberedItem(trimmed) {
                var items: [String] = []
                while i < lines.count, let itemLine = Self.numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(itemLine)
                    i += 1
                }
                blocks.append(.numbered(items: items))
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

    private static func bulletItem(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(_ trimmed: String) -> String? {
        let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let number = parts.first,
              !number.isEmpty,
              number.allSatisfy({ $0.isNumber }),
              let rest = parts.last,
              rest.first == " " else {
            return nil
        }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isBlockStart(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") { return true }
        if heading(trimmed) != nil { return true }
        if isRule(trimmed) { return true }
        if bulletItem(trimmed) != nil { return true }
        if numberedItem(trimmed) != nil { return true }
        return false
    }
}
