import Foundation

/// How a model family likes to be prompted. Used to steer rewrites and to warn when a prompt is
/// longer than the model handles well. Chosen from the provider id; a heuristic, not a promise.
public struct ModelPromptProfile: Sendable, Equatable {

    public enum Structure: String, Sendable, Equatable { case xmlTags, markdown, plainNumbered }

    /// Key for `SavedPrompt.modelVariants`.
    public let family: String
    public let displayName: String
    public let structure: Structure
    /// A prompt longer than this (in tokens) is flagged by the lint and the token meter.
    public let maxUsefulTokens: Int
    /// One or two sentences handed to the rewriter about the target's style.
    public let guidance: String

    public static let localSmall = ModelPromptProfile(
        family: "local", displayName: "Model on this Mac", structure: .plainNumbered, maxUsefulTokens: 1_500,
        guidance: "The target is a small local model. Use short plain sentences, one task per prompt, and a numbered list for constraints. Name files and symbols explicitly. Avoid nested instructions.")
    public static let claude = ModelPromptProfile(
        family: "claude", displayName: "Claude", structure: .xmlTags, maxUsefulTokens: 20_000,
        guidance: "The target is Claude. Put background in <context> tags, the task in <task>, and requirements in a short list. Be direct about the desired output format.")
    public static let gpt = ModelPromptProfile(
        family: "gpt", displayName: "GPT", structure: .markdown, maxUsefulTokens: 12_000,
        guidance: "The target is a GPT model. Use a short Markdown structure: a one-line goal, then bullet-point requirements, then the desired output format.")
    public static let generic = ModelPromptProfile(
        family: "generic", displayName: "Cloud model", structure: .markdown, maxUsefulTokens: 8_000,
        guidance: "State the goal first, then the requirements as a short list, then the desired output format.")

    public static func profile(forProviderID id: String?) -> ModelPromptProfile {
        guard let id = id?.lowercased() else { return .generic }
        if id.hasPrefix("local:") || id.contains("bonsai") || id.contains("qwen") || id.contains("mlx") { return .localSmall }
        if id.contains("claude") || id.contains("anthropic") { return .claude }
        if id.contains("gpt") || id.contains("openai") || id.hasPrefix("o1") || id.hasPrefix("o3") { return .gpt }
        return .generic
    }
}

/// Rough size of a piece of text in tokens (deliberately pessimistic for code, like the router).
public enum PromptTokens {
    public static func estimate(_ text: String) -> Int {
        text.isEmpty ? 0 : max(1, Int((Double(text.count) / 2.5).rounded(.up)))
    }
}
