import Foundation

/// What ships in the library on first launch.
public enum BuiltInPrompts {

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
