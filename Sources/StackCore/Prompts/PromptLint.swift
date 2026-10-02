import Foundation

/// Instant, model-free checks on a draft. Each finding says what is missing and, where it can,
/// offers a line to add. Pure functions, so they can run on every keystroke.
public enum PromptLint {

    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Rule: String, Sendable { case tooShort, noTarget, noSuccessCriterion, errorWithoutQuestion, multipleAsks, tooLong, unbalancedXML, chainOfThought, goalNotFirst }
        public let rule: Rule
        public let message: String
        /// Text the user can append with one click, if there is an obvious one.
        public let suggestion: String?
        public var id: String { rule.rawValue }
    }

    public struct Context: Sendable {
        public var maxTokens: Int?
        public var intent: String?
        public var modelFamily: String?
        public init(maxTokens: Int? = nil, intent: String? = nil, modelFamily: String? = nil) {
            self.maxTokens = maxTokens
            self.intent = intent
            self.modelFamily = modelFamily
        }
    }

    /// Pairs of clauses in `text` that ask for opposite things (brief against detailed), verbatim. The
    /// rewriter has to pick one, so the validator must not demand both back.
    public static func conflicts(_ text: String) -> [(String, String)] {
        let brief = ["short", "brief", "concise", "terse", "one line", "one sentence"]
        let deep = ["great detail", "in detail", "in depth", "thorough", "comprehensive", "exhaustive", "everything"]
        let clauses = PromptLiterals.clauses(in: text)
        guard let a = clauses.first(where: { c in brief.contains { c.lowercased().contains($0) } }),
              let b = clauses.first(where: { c in c != a && deep.contains { c.lowercased().contains($0) } })
        else { return [] }
        return [(a, b)]
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

        switch context.modelFamily {
        case "claude" where unbalancedTags(trimmed):
            out.append(.init(rule: .unbalancedXML, message: "A tag is opened but not closed.", suggestion: nil))
        case "reasoning" where hasChainOfThoughtPhrase(trimmed):
            out.append(.init(rule: .chainOfThought, message: "This model reasons on its own. Drop the reasoning instruction.", suggestion: nil))
        case "gpt" where !startsWithGoal(trimmed):
            out.append(.init(rule: .goalNotFirst, message: "Open with a one-line goal before the list.", suggestion: nil))
        default: break
        }

        return out
    }

    /// True when a rewrite has nothing to add: a real-length draft with no lint findings, at least two
    /// literals to anchor it, a stated success check, and none of the vague words a rewrite would pin down.
    public static func isAlreadyClear(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard (12...80).contains(words.count), check(trimmed).isEmpty,
              PromptLiterals.extract(from: trimmed).count >= 2,
              containsAny(lower, ["must", "should", "done when", "passes", "verify", "expect", "succeeds", "exits", "completes", "compiles"])
        else { return false }
        let vague: Set<String> = ["better", "faster", "nicer", "improve", "optimize", "good", "properly", "somehow", "stuff", "etc"]
        return vague.isDisjoint(with: words)
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

    /// True if the text has unbalanced XML-style tags (well-formed names only; < in prose like "a < b" is ignored).
    /// Ignores tags inside fenced blocks (```), inline backticks (`), self-closing tags (<tag/>),
    /// and HTML void tags (br, hr, img, input, meta, link).
    private static func unbalancedTags(_ text: String) -> Bool {
        // Remove fenced code blocks
        var working = text
        let fencePattern = "```[\\s\\S]*?```"
        if let fenceRegex = try? NSRegularExpression(pattern: fencePattern) {
            let nsWorking = working as NSString
            let fenceMatches = fenceRegex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
            for match in fenceMatches.reversed() {
                let range = match.range
                let start = working.index(working.startIndex, offsetBy: range.location)
                let end = working.index(start, offsetBy: range.length)
                working.replaceSubrange(start..<end, with: "")
            }
        }

        // Remove inline backticks with contents
        let backtickPattern = "`[^`]*`"
        if let backtickRegex = try? NSRegularExpression(pattern: backtickPattern) {
            let nsWorking = working as NSString
            let backtickMatches = backtickRegex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
            for match in backtickMatches.reversed() {
                let range = match.range
                let start = working.index(working.startIndex, offsetBy: range.location)
                let end = working.index(start, offsetBy: range.length)
                working.replaceSubrange(start..<end, with: "")
            }
        }

        let regex = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9_-]*)[^<>]*?(/?)>")
        var stack: [String] = []
        let ns = working as NSString
        let voidTags = Set(["br", "hr", "img", "input", "meta", "link"])

        for m in regex.matches(in: working, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let selfClosing = ns.substring(with: m.range(at: 3)) == "/"

            // Skip void tags and self-closing tags
            if voidTags.contains(name) || selfClosing {
                continue
            }

            if closing {
                guard stack.last?.lowercased() == name else { return true }
                stack.removeLast()
            } else {
                stack.append(name)
            }
        }
        return !stack.isEmpty
    }

    /// True if the text doesn't start with a goal (no leading list marker or header).
    /// Trims leading whitespace. Numbered items (1., 2), indented bullets (-, *, +),
    /// headings (#), blockquotes (>), and fences (```) are NOT goals.
    /// A single backtick followed by prose (e.g., "`loadItems` should...") IS a goal.
    private static func startsWithGoal(_ text: String) -> Bool {
        guard let first = text.split(separator: "\n").first else { return true }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }

        // Check for numbered list items: "1.", "2)", etc.
        if let firstChar = trimmed.first, firstChar.isNumber {
            let digits = trimmed.prefix(while: { $0.isNumber })
            let afterDigits = String(trimmed.dropFirst(digits.count))
            if afterDigits.hasPrefix(".") || afterDigits.hasPrefix(")") {
                return false // Not a goal
            }
        }

        // Check for bullet markers
        let bulletMarkers = ["-", "*", "+"]
        if bulletMarkers.contains(where: { trimmed.hasPrefix($0) }) {
            return false // Not a goal
        }

        // Check for headings, blockquotes, and triple-backtick fences
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("```") {
            return false // Not a goal
        }

        // Check for single backtick: if it starts with ` but not ```, and contains prose, it's a goal
        if trimmed.hasPrefix("`") && !trimmed.hasPrefix("```") {
            return true // Single backtick with prose is a goal
        }

        return true // Everything else is a goal
    }

    /// True if text contains chain-of-thought phrases, excluding those in quotes, backticks, fences, or negated forms.
    private static func hasChainOfThoughtPhrase(_ text: String) -> Bool {
        let phrases = ["step by step", "show your reasoning", "think aloud", "chain of thought"]
        let lower = text.lowercased()

        // Remove fenced code blocks
        var working = lower
        let fencePattern = "```[\\s\\S]*?```"
        if let fenceRegex = try? NSRegularExpression(pattern: fencePattern) {
            let nsWorking = working as NSString
            let fenceMatches = fenceRegex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
            for match in fenceMatches.reversed() {
                let range = match.range
                let start = working.index(working.startIndex, offsetBy: range.location)
                let end = working.index(start, offsetBy: range.length)
                working.replaceSubrange(start..<end, with: "")
            }
        }

        // Remove quoted strings (double and single quotes)
        let quotePattern = "\"[^\"]*\"|'[^']*'"
        if let quoteRegex = try? NSRegularExpression(pattern: quotePattern) {
            let nsWorking = working as NSString
            let quoteMatches = quoteRegex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
            for match in quoteMatches.reversed() {
                let range = match.range
                let start = working.index(working.startIndex, offsetBy: range.location)
                let end = working.index(start, offsetBy: range.length)
                working.replaceSubrange(start..<end, with: "")
            }
        }

        // Remove backtick contents
        let backtickPattern = "`[^`]*`"
        if let backtickRegex = try? NSRegularExpression(pattern: backtickPattern) {
            let nsWorking = working as NSString
            let backtickMatches = backtickRegex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
            for match in backtickMatches.reversed() {
                let range = match.range
                let start = working.index(working.startIndex, offsetBy: range.location)
                let end = working.index(start, offsetBy: range.length)
                working.replaceSubrange(start..<end, with: "")
            }
        }

        // Remove negated clauses: "(don't|do not|never|no) [^.!?]*"
        let negationPattern = "\\b(don't|do not|never|no)\\b[^.!?]*"
        if let negationRegex = try? NSRegularExpression(pattern: negationPattern) {
            let nsWorking = working as NSString
            let negationMatches = negationRegex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
            for match in negationMatches.reversed() {
                let range = match.range
                let start = working.index(working.startIndex, offsetBy: range.location)
                let end = working.index(start, offsetBy: range.length)
                working.replaceSubrange(start..<end, with: " ")
            }
        }

        // Check if any phrase appears with word boundaries
        for phrase in phrases {
            let escapedPhrase = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = "\\b\(escapedPhrase)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsWorking = working as NSString
                if regex.firstMatch(in: working, range: NSRange(location: 0, length: nsWorking.length)) != nil {
                    return true
                }
            }
        }

        return false
    }
}
