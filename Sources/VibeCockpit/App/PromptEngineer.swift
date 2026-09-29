import Foundation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Classifies a user prompt and transforms the message array before LLM delivery.
/// Pure value type — no I/O, no LLM calls, fully unit-testable.
public struct PromptEngineer {

    // MARK: - Intent classification

    public enum Intent: String, Sendable, Equatable {
        case generate   // write new code, add feature, create file
        case debug      // fix bug, error, crash, not working
        case refactor   // clean up, rename, restructure, simplify
        case explain    // what does, how does, why does
        case test       // write tests, add coverage, unit test
        case review     // review, check, audit, feedback
        case general    // catch-all
    }

    private static let patterns: [(Intent, [String])] = [
        (.generate, ["create", "add", "implement", "build", "generate", "write", "make", "new file",
                     "scaffold", "boilerplate", "feature"]),
        (.debug,    ["fix", "bug", "error", "crash", "broken", "not working", "fails", "failure",
                     "exception", "issue", "problem", "wrong", "incorrect", "doesn't work"]),
        (.refactor, ["refactor", "clean", "rename", "restructure", "simplify", "improve",
                     "reorganize", "extract", "move", "split", "merge"]),
        (.explain,  ["explain", "what does", "how does", "why does", "what is", "how is",
                     "describe", "understand", "tell me about", "walk me through"]),
        (.test,     ["test", "spec", "coverage", "unit test", "integration test", "mock", "stub",
                     "assert", "expectation"]),
        (.review,   ["review", "check", "audit", "feedback", "look at", "evaluate", "assess",
                     "is this correct", "is this right", "critique"]),
    ]

    /// Whole-word matching: "add" does not match "address", "move" does not match "remove".
    /// A keyword also matches its plain inflections (test → tests, fix → fixed, create → creating).
    public static func classify(_ prompt: String) -> Intent {
        let normalized = " " + normalize(prompt) + " "
        let words = Set(normalized.split(separator: " ").map(String.init))
        var bestScore = 0
        var bestIntent = Intent.general
        for (intent, keywords) in patterns {
            let score = keywords.filter { matches($0, normalized: normalized, words: words) }.count
            if score >= bestScore, score > 0 {
                bestScore = score
                bestIntent = intent
            }
        }
        return bestIntent
    }

    private static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    private static func matches(_ keyword: String, normalized: String, words: Set<String>) -> Bool {
        if keyword.contains(" ") { return normalized.contains(" \(keyword) ") }
        if words.contains(keyword) { return true }
        var forms = [keyword + "s", keyword + "es", keyword + "ed", keyword + "d", keyword + "ing"]
        if keyword.hasSuffix("e") { forms.append(String(keyword.dropLast()) + "ing") }
        return forms.contains { words.contains($0) }
    }

    // MARK: - Message transformation

    /// Applies intent-specific prompt engineering to the assembled message array.
    /// Modifies the system message and optionally the final user message.
    public static func engineer(messages: [Message], intent: Intent) -> [Message] {
        guard !messages.isEmpty else { return messages }
        var result = messages

        // Augment system message with intent-specific instructions
        if let sysIdx = result.indices.first(where: { result[$0].role == .system }) {
            let extra = systemAddendum(for: intent)
            result[sysIdx] = Message(
                role: .system,
                content: result[sysIdx].content + "\n\n" + extra
            )
        }

        // Augment the final user message with a structured framing prefix
        if let userIdx = result.indices.reversed().first(where: { result[$0].role == .user }) {
            let framing = userFraming(for: intent)
            if let framing {
                result[userIdx] = Message(
                    role: .user,
                    content: framing + result[userIdx].content
                )
            }
        }

        return result
    }

    /// Build the full text of one user turn — intent guidance, task framing, retrieved context,
    /// then the request — exactly once. The caller stores the result verbatim (see
    /// `PromptLedger`) instead of re-deriving it each request, so earlier turns never change and
    /// the model's prefix cache stays valid. Guidance lives here rather than in the system
    /// message because the system message is fixed for the whole session.
    ///
    /// `recipe` is the guidance from the prompt library: `nil` means use the built-in text, an empty
    /// string means the user switched this task's guidance off.
    public static func augmentUserTurn(_ text: String, intent: Intent, ragContext: String?, recipe: String? = nil) -> String {
        let body = ragContext.map { "\($0)\n\nUser request: \(text)" } ?? text
        let framed = (userFraming(for: intent) ?? "") + body
        let guidance = recipe ?? systemAddendum(for: intent)
        return guidance.isEmpty ? framed : guidance + "\n\n" + framed
    }

    // MARK: - Per-intent content

    /// The shipped guidance; the prompt library holds the user's editable copy (see `BuiltInPrompts`).
    private static func systemAddendum(for intent: Intent) -> String {
        BuiltInPrompts.recipeText(for: intent.rawValue)
    }

    private static func userFraming(for intent: Intent) -> String? {
        switch intent {
        case .debug:
            return "[Task: debug]\n"
        case .generate:
            return "[Task: generate]\n"
        case .refactor:
            return "[Task: refactor]\n"
        case .explain:
            return "[Task: explain]\n"
        case .test:
            return "[Task: test]\n"
        case .review:
            return "[Task: review]\n"
        case .general:
            return nil
        }
    }
}
