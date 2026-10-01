import Foundation

/// Instant, model-free checks on a draft. Each finding says what is missing and, where it can,
/// offers a line to add. Pure functions, so they can run on every keystroke.
public enum PromptLint {

    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Rule: String, Sendable { case tooShort, noTarget, noSuccessCriterion, errorWithoutQuestion, multipleAsks, tooLong }
        public let rule: Rule
        public let message: String
        /// Text the user can append with one click, if there is an obvious one.
        public let suggestion: String?
        public var id: String { rule.rawValue }
    }

    public struct Context: Sendable {
        public var maxTokens: Int?
        public var intent: String?
        public init(maxTokens: Int? = nil, intent: String? = nil) {
            self.maxTokens = maxTokens
            self.intent = intent
        }
    }

    public static func check(_ text: String, context: Context = Context()) -> [Finding] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [Finding] = []
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        let hasCode = trimmed.contains("```") || trimmed.contains("`")
        let lower = trimmed.lowercased()

        if words.count < 4 && !hasCode {
            out.append(.init(rule: .tooShort, message: "Say what you want done, and to what.", suggestion: nil))
        }

        if words.count < 15, !hasCode, !mentionsFile(trimmed), refersVaguely(lower) {
            out.append(.init(rule: .noTarget, message: "“it” or “this” has nothing to point at. Name the file or paste the code.",
                             suggestion: "\n\nFile: "))
        }

        if ["generate", "debug", "refactor", "test"].contains(context.intent ?? ""), words.count < 30,
           !containsAny(lower, ["should", "must", "expect", "so that", "returns", "instead of", "result", "done when", "passes", "verify"]) {
            out.append(.init(rule: .noSuccessCriterion, message: "Say what a good result looks like.",
                             suggestion: "\n\nIt should: "))
        }

        if isErrorOnly(trimmed) {
            out.append(.init(rule: .errorWithoutQuestion, message: "You pasted an error but didn't say what you need.",
                             suggestion: "\n\nWhat is causing this, and what is the smallest fix?"))
        }

        if trimmed.filter({ $0 == "?" }).count >= 3 || lower.components(separatedBy: " also ").count >= 3 {
            out.append(.init(rule: .multipleAsks, message: "That's several requests. Smaller models do better with one per message.", suggestion: nil))
        }

        if let max = context.maxTokens, PromptTokens.estimate(trimmed) > max {
            out.append(.init(rule: .tooLong, message: "This is longer than this model handles well (about \(max) tokens). Trim it or split it.", suggestion: nil))
        }
        return out
    }

    // MARK: Helpers

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func refersVaguely(_ lower: String) -> Bool {
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["it", "this", "that", "these", "those"])
    }

    /// True if the text names something concrete: a path, or a file with a code extension.
    static func mentionsFile(_ text: String) -> Bool {
        text.range(of: #"[\w./-]+/[\w.-]+|\b[\w-]+\.(swift|md|json|yml|yaml|plist|txt|py|js|ts|c|h|m|sh|toml)\b"#,
                   options: .regularExpression) != nil
    }

    /// True when the text is an error message with (almost) nothing said about it.
    private static func isErrorOnly(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let isError: (Substring) -> Bool = {
            let l = $0.lowercased()
            return l.contains("error:") || l.contains("fatal error") || l.contains("exception") || l.contains("failed:")
        }
        guard lines.contains(where: isError) else { return false }
        let prose = lines.filter { !isError($0) }.joined(separator: " ").split(whereSeparator: { $0.isWhitespace })
        return prose.count < 3 && !text.contains("?")
    }
}
