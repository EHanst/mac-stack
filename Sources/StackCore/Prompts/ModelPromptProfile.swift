import Foundation

/// How a model family likes to be prompted. Used to steer rewrites and to warn when a prompt is
/// longer than the model handles well. Chosen from the provider id; a heuristic, not a promise.
public struct ModelPromptProfile: Sendable, Equatable {

    public enum Structure: String, Sendable, Equatable { case xmlTags, markdown, plainNumbered }
    public enum ReasoningCuePolicy: String, Sendable, Equatable { case allow, avoid }
    public enum Verbosity: String, Sendable, Equatable { case concise, normal }

    /// Key for `SavedPrompt.modelVariants`.
    public let family: String
    public let displayName: String
    public let structure: Structure
    /// A prompt longer than this (in tokens) is flagged by the lint and the token meter.
    public let maxUsefulTokens: Int
    /// One or two sentences handed to the rewriter about the target's style.
    public let guidance: String
    public let reasoningCue: ReasoningCuePolicy
    public let outputFormatWording: String
    public let verbosity: Verbosity

    public init(family: String, displayName: String, structure: Structure, maxUsefulTokens: Int,
                guidance: String, reasoningCue: ReasoningCuePolicy = .allow,
                outputFormatWording: String = "", verbosity: Verbosity = .normal) {
        self.family = family
        self.displayName = displayName
        self.structure = structure
        self.maxUsefulTokens = maxUsefulTokens
        self.guidance = guidance
        self.reasoningCue = reasoningCue
        self.outputFormatWording = outputFormatWording
        self.verbosity = verbosity
    }

    /// `guidance` plus the typed style rules, for the rewriter.
    public var rewriterGuidance: String {
        var parts = [guidance]
        if reasoningCue == .avoid { parts.append("Do not ask the model to think step by step.") }
        if !outputFormatWording.isEmpty { parts.append(outputFormatWording) }
        if verbosity == .concise { parts.append("Keep the prompt short.") }
        return parts.joined(separator: " ")
    }

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
    public static let gemini = ModelPromptProfile(
        family: "gemini", displayName: "Gemini", structure: .markdown, maxUsefulTokens: 30_000,
        guidance: "The target is Gemini. Use a short Markdown brief: a one-line goal, short bullets, then the exact output format.",
        outputFormatWording: "State the required output format early.")
    /// OpenAI o-series reasoning models (o1, o3, etc.). Do not use for DeepSeek-R1.
    public static let reasoning = ModelPromptProfile(
        family: "reasoning", displayName: "Reasoning model", structure: .plainNumbered, maxUsefulTokens: 10_000,
        guidance: "The target is a reasoning model. State the problem, the constraints and the required output.",
        reasoningCue: .avoid, outputFormatWording: "End with the required output format.", verbosity: .concise)
    public static let deepseekR1 = ModelPromptProfile(
        family: "deepseek", displayName: "DeepSeek-R1", structure: .plainNumbered, maxUsefulTokens: 8_000,
        guidance: "The target is DeepSeek-R1. Use plain language, put every instruction in the user prompt, and keep it concrete.",
        reasoningCue: .allow, outputFormatWording: "", verbosity: .concise)
    public static let claudeCode = ModelPromptProfile(
        family: "claude", displayName: "Claude Code", structure: .xmlTags, maxUsefulTokens: 20_000,
        guidance: "The target is Claude Code, which reads the repo itself. State the goal, name the files and symbols, and say what done looks like.",
        verbosity: .concise)

    public static func profile(forProviderID id: String?) -> ModelPromptProfile {
        guard let id = id?.lowercased() else { return .generic }
        // Check local: first for priority
        if id.hasPrefix("local:") { return .localSmall }
        // Bonsai is kept for possible use without local: prefix
        if id.contains("bonsai") { return .localSmall }
        if id.contains("gemini") { return .gemini }
        if id.contains("deepseek-r1") { return .deepseekR1 }
        // Check for o1/o3 at word boundaries using regex
        if let oSeriesRegex = try? NSRegularExpression(pattern: "(^|[/:-])o[13]([-.]|$)") {
            let nsID = id as NSString
            if oSeriesRegex.firstMatch(in: id, range: NSRange(location: 0, length: nsID.length)) != nil {
                return .reasoning
            }
        }
        if id.contains("claude") || id.contains("anthropic") { return .claude }
        if id.contains("gpt") || id.contains("openai") { return .gpt }
        return .generic
    }
}

/// Rough size of a piece of text in tokens (deliberately pessimistic for code, like the router).
public enum PromptTokens {
    public static func estimate(_ text: String) -> Int {
        text.isEmpty ? 0 : max(1, Int((Double(text.count) / 2.5).rounded(.up)))
    }
}
