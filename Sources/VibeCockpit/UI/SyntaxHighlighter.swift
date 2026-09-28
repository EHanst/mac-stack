#if canImport(AppKit)
import AppKit

public enum SourceLanguage: Sendable {
    case swift, json, plainText
}

/// Lightweight NSAttributedString-based syntax highlighter.
/// No external dependencies. Covers the 90% case needed for diff canvas display.
public struct SyntaxHighlighter {

    public struct Theme {
        public let keyword: NSColor
        public let string: NSColor
        public let comment: NSColor
        public let type_: NSColor
        public let number: NSColor
        public let plain: NSColor
        public let background: NSColor

        public static let dark = Theme(
            keyword: .systemPink,
            string:  .systemGreen,
            comment: .systemGray,
            type_:   .systemCyan,
            number:  .systemOrange,
            plain:   .labelColor,
            background: NSColor(white: 0.1, alpha: 1)
        )

        public static let light = Theme(
            keyword: NSColor(red: 0.64, green: 0.05, blue: 0.71, alpha: 1),
            string:  NSColor(red: 0.13, green: 0.5, blue: 0.25, alpha: 1),
            comment: NSColor(red: 0.39, green: 0.44, blue: 0.49, alpha: 1),
            type_:   NSColor(red: 0.17, green: 0.43, blue: 0.75, alpha: 1),
            number:  NSColor(red: 0.6, green: 0.2, blue: 0.0, alpha: 1),
            plain:   .textColor,
            background: .textBackgroundColor
        )
    }

    private let theme: Theme
    private let font: NSFont

    public init(theme: Theme = .dark, font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) {
        self.theme = theme
        self.font = font
    }

    public func highlight(_ source: String, language: SourceLanguage) -> NSAttributedString {
        switch language {
        case .swift: return highlightSwift(source)
        case .json: return highlightJSON(source)
        case .plainText: return plain(source)
        }
    }

    // MARK: - Private

    private func highlightSwift(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source)
        let range = NSRange(source.startIndex..., in: source)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.plain]
        result.addAttributes(base, range: range)

        let patterns: [(pattern: String, color: NSColor)] = [
            // Single-line comments
            (#"//[^\n]*"#, theme.comment),
            // Multi-line comments
            (#"/\*[\s\S]*?\*/"#, theme.comment),
            // String literals
            (#""[^"\\]*(?:\\.[^"\\]*)*""#, theme.string),
            // Numbers
            (#"\b\d+\.?\d*\b"#, theme.number),
            // Keywords
            (#"\b(let|var|func|class|struct|enum|protocol|extension|actor|import|return|if|else|guard|switch|case|default|for|while|do|try|catch|throw|throws|rethrows|async|await|init|deinit|self|super|static|final|override|public|private|internal|fileprivate|open|mutating|nonmutating|lazy|weak|unowned|in|where|typealias|associatedtype|some|any|true|false|nil|is|as|@discardableResult|@MainActor|@Sendable)\b"#, theme.keyword),
            // Type names (capitalized identifiers)
            (#"\b[A-Z][a-zA-Z0-9_]*\b"#, theme.type_),
        ]

        for (pattern, color) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                for match in regex.matches(in: source, range: range) {
                    result.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        return result
    }

    private func highlightJSON(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source)
        let range = NSRange(source.startIndex..., in: source)
        result.addAttributes([.font: font, .foregroundColor: theme.plain], range: range)
        let patterns: [(String, NSColor)] = [
            (#""[^"]*"\s*:"#, theme.keyword),
            (#":\s*"[^"]*""#, theme.string),
            (#"\b(true|false|null)\b"#, theme.number),
            (#"\b-?\d+\.?\d*([eE][+-]?\d+)?\b"#, theme.number),
        ]
        for (pattern, color) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: source, range: range) {
                    result.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        return result
    }

    private func plain(_ source: String) -> NSAttributedString {
        NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: theme.plain])
    }
}
#endif
