import Foundation

/// The prompt-engineering rules every prompt in the app follows. One constant block, so it can sit in a
/// system prompt without changing between turns (the local prefix cache needs that), and so the sidecar,
/// the optimizer and the lint all teach the same thing. Change it in one pass: any edit
/// invalidates every cached prefix that includes it.
public enum PromptPrinciples {

    /// Baseline default word limit for local small models.
    public static let defaultWordLimit = 120

    nonisolated(unsafe) private static var customWordLimit: Int?

    /// Current word limit. Defaults to `defaultWordLimit`, or returns the custom override if set.
    public static var wordLimit: Int {
        get { customWordLimit ?? defaultWordLimit }
        set { customWordLimit = newValue }
    }

    /// Dynamically calculates the word budget based on the model profile, context limit, or system state.
    public static func wordLimit(for profile: ModelPromptProfile? = nil, contextLimit: Int? = nil) -> Int {
        if let custom = customWordLimit { return custom }
        if let profile {
            switch profile.family {
            case "local":
                return profile.verbosity == .concise ? 100 : 120
            case "claude", "gemini":
                return 250
            case "gpt", "reasoning":
                return 180
            default:
                return profile.maxUsefulTokens >= 10_000 ? 200 : defaultWordLimit
            }
        }
        if let contextLimit {
            return max(80, min(350, Int(Double(contextLimit) * 0.08 / 1.3)))
        }
        return defaultWordLimit
    }

    /// Sets or clears a custom word limit override.
    public static func setCustomWordLimit(_ limit: Int?) {
        customWordLimit = limit
    }

    /// Canonical rules block for local small models. Keeps under default wordLimit and remains byte-identical for prefix caching.
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

    /// Extended rules block for capable cloud models, expanding requirements while including all baseline rules.
    public static let expandedRules = """
        Good prompts:
        1. One task per prompt.
        2. State the goal and what done looks like: acceptance criteria and how to verify them.
        3. Name the exact files, symbols, commands and versions. Never invent one: write "unspecified" or ask.
        4. Give constraints and non-goals: what to keep, what not to change.
        5. Put the data (code, errors, logs) first and the instruction last.
        6. Say what to do, not only what to avoid.
        7. State the output format once.
        8. Number the steps; one action per step.
        9. Specify edge cases, failure recovery, and missing input handling.
        10. Preserve schema delimiters and required output tags.
        """

    /// Selects the appropriate rules block based on the target model profile.
    public static func rules(for profile: ModelPromptProfile? = nil) -> String {
        guard let profile else { return rules }
        switch profile.family {
        case "local":
            return rules
        case "claude", "gemini", "gpt":
            return profile.verbosity == .concise ? rules : expandedRules
        default:
            return profile.maxUsefulTokens >= 10_000 ? expandedRules : rules
        }
    }
}

