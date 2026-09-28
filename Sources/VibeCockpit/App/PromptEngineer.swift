import Foundation

/// Classifies a user prompt and transforms the message array before LLM delivery.
/// Pure value type — no I/O, no LLM calls, fully unit-testable.
public struct PromptEngineer {

    // MARK: - Intent classification

    public enum Intent: Sendable, Equatable {
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

    public static func classify(_ prompt: String) -> Intent {
        let lower = prompt.lowercased()
        var bestScore = 0
        var bestIntent = Intent.general
        for (intent, keywords) in patterns {
            let score = keywords.filter { lower.contains($0) }.count
            if score >= bestScore, score > 0 {
                bestScore = score
                bestIntent = intent
            }
        }
        return bestIntent
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

    // MARK: - Per-intent content

    private static func systemAddendum(for intent: Intent) -> String {
        switch intent {
        case .generate:
            return """
                When generating code:
                - Produce complete, compilable Swift. Do not use placeholder comments like "// TODO" unless the user asked for a skeleton.
                - Follow Swift API Design Guidelines. Prefer value types. Use async/await over completion handlers.
                - State the file path of each new or modified file before its code block.
                """
        case .debug:
            return """
                When debugging:
                - First identify the root cause before proposing a fix. State it explicitly.
                - Show the minimal diff that resolves the issue — avoid unrelated changes.
                - If the fix requires understanding runtime state you cannot see, list what information would confirm the diagnosis.
                """
        case .refactor:
            return """
                When refactoring:
                - Preserve observable behaviour exactly. Do not change public API signatures without flagging it.
                - Prefer small, reviewable steps over large rewrites.
                - Call out any renamed symbols that callers outside the current file will need to update.
                """
        case .explain:
            return """
                When explaining code:
                - Lead with the high-level purpose before implementation details.
                - Use concrete examples where helpful.
                - Keep jargon to a minimum; define any Swift/concurrency-specific terms you use.
                """
        case .test:
            return """
                When writing tests:
                - Use Swift Testing (@Test, #expect) for new test files. Only use XCTest if the existing suite already uses it.
                - Each test should cover exactly one behaviour. Name tests descriptively.
                - Include at least one edge-case and one failure-path test per function under test.
                """
        case .review:
            return """
                When reviewing code:
                - Categorise each finding: correctness, performance, style, or security.
                - Be specific: quote the problematic line and explain why it is an issue.
                - Distinguish must-fix from nice-to-have.
                """
        case .general:
            return "Think step by step before responding. Be concise and specific to the codebase."
        }
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
