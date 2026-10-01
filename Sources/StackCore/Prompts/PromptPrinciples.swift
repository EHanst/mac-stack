import Foundation

/// The prompt-engineering rules every prompt in the app follows. One constant block, so it can sit in a
/// system prompt without changing between turns (the local prefix cache needs that), and so the chat
/// assistant, the optimizer and the lint all teach the same thing. Change it in one pass: any edit
/// invalidates every cached prefix that includes it.
public enum PromptPrinciples {

    /// Longest the block may be, in words. It rides along with every conversation on a small local model.
    public static let wordLimit = 120

    public static let rules = """
        Good prompts:
        1. One task per prompt.
        2. State the goal and what done looks like: acceptance criteria and how to verify them.
        3. Name the exact files, symbols, commands and versions. Never invent one: write "unspecified" or ask.
        4. Give constraints and non-goals: what to keep, what not to change.
        5. Put the data (code, errors, logs) first and the instruction last.
        6. Say what to do, not only what to avoid.
        7. State the output format once.
        8. Number the steps; one action per step.
        """
}
