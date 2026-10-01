import Foundation

/// What ships in the library on first launch.
public enum BuiltInPrompts {

    /// Task keys, shared with `PromptEngineer.Intent`.
    public static let intents = ["generate", "debug", "refactor", "explain", "test", "review", "general"]

    /// Per-task guidance applied to a turn. These are exactly the strings the app used before
    /// recipes became editable, so behaviour is unchanged until the user edits one.
    public static func recipeText(for intent: String) -> String {
        switch intent {
        case "generate":
            return """
                When generating code:
                - Produce complete, compilable Swift. Do not use placeholder comments like "// TODO" unless the user asked for a skeleton.
                - Follow Swift API Design Guidelines. Prefer value types. Use async/await over completion handlers.
                - State the file path of each new or modified file before its code block.
                """
        case "debug":
            return """
                When debugging:
                - First identify the root cause before proposing a fix. State it explicitly.
                - Show the minimal diff that resolves the issue — avoid unrelated changes.
                - If the fix requires understanding runtime state you cannot see, list what information would confirm the diagnosis.
                """
        case "refactor":
            return """
                When refactoring:
                - Preserve observable behaviour exactly. Do not change public API signatures without flagging it.
                - Prefer small, reviewable steps over large rewrites.
                - Call out any renamed symbols that callers outside the current file will need to update.
                """
        case "explain":
            return """
                When explaining code:
                - Lead with the high-level purpose before implementation details.
                - Use concrete examples where helpful.
                - Keep jargon to a minimum; define any Swift/concurrency-specific terms you use.
                """
        case "test":
            return """
                When writing tests:
                - Use Swift Testing (@Test, #expect) for new test files. Only use XCTest if the existing suite already uses it.
                - Each test should cover exactly one behaviour. Name tests descriptively.
                - Include at least one edge-case and one failure-path test per function under test.
                - Say how to run the tests and what passing looks like.
                """
        case "review":
            return """
                When reviewing code:
                - Categorise each finding: correctness, performance, style, or security.
                - Be specific: quote the problematic line and explain why it is an issue.
                - Distinguish must-fix from nice-to-have.
                """
        default:
            return "Be concise and specific to the codebase. If the request is ambiguous, ask one short question before acting."
        }
    }

    public static func recipeID(for intent: String) -> String { "builtin.recipe.\(intent)" }

    public static var recipes: [SavedPrompt] {
        intents.map { intent in
            SavedPrompt(
                id: recipeID(for: intent), kind: .recipe,
                title: "Guidance for “\(intent)” requests", body: recipeText(for: intent),
                tags: ["recipe"], recipeIntent: intent, builtIn: true)
        }
    }

    /// A small Swift starter pack. Variables in `{{…}}` are filled in when the prompt is used.
    public static var starters: [SavedPrompt] {
        func make(_ id: String, _ title: String, _ slash: String, _ tags: [String], _ body: String) -> SavedPrompt {
            SavedPrompt(id: "builtin.starter.\(id)", title: title, body: body, tags: tags, slash: slash, builtIn: true)
        }
        return [
            make("review", "Review a file", "review", ["review"], """
                Review {{file}} for correctness, concurrency problems and unclear naming.
                List must-fix items first, then nice-to-have. Quote the line for each finding.
                """),
            make("tests", "Write tests", "tests", ["test"], """
                Write Swift Testing tests for {{target}}.
                Cover the normal case, one edge case and one failure path. Name each test after the behaviour it checks.
                """),
            make("bug", "Fix a bug", "bug", ["debug"], """
                {{symptom}}
                Expected: {{expected}}
                Find the root cause in {{file}} and show the smallest change that fixes it.
                """),
            make("refactor", "Refactor safely", "refactor", ["refactor"], """
                Refactor {{target}} to {{goal}}.
                Keep behaviour and public signatures the same, and list anything callers must update.
                """),
            make("explain", "Explain this code", "explain", ["explain"], """
                Explain what {{target}} does and why it is written this way. Start with the purpose, then walk through the flow.
                """),
            make("swiftui", "New SwiftUI view", "view", ["generate", "swiftui"], """
                Create a SwiftUI view called {{name}} that {{purpose}}.
                Use @Observable for state, keep it under 120 lines, and include a #Preview.
                """),
            make("actor", "Move to an actor", "actor", ["refactor", "concurrency"], """
                Convert {{target}} to an actor (or an @MainActor type if it touches UI). Remove locks and completion handlers, keep the public API async, and make the types Sendable.
                """),
        ]
    }
}
