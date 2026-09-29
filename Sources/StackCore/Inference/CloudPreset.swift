import Foundation

/// Ready-made settings for the providers people actually use, so adding one is "pick, paste key".
/// Base URLs were checked against each provider's own docs on 2026-09-29. No prices live here.
public struct CloudPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let apiStyle: RemoteAPIProvider.APIStyle
    /// A model to start from; nil where the catalogue is too large to guess (the user names one).
    public let suggestedModel: String?
    public let keyRequired: Bool
    public let keyHint: String
    public let modelHint: String

    /// The user's own key never has to be a "vc_" or "sk-" shape, so nothing here validates its format.
    public static let all: [CloudPreset] = [
        CloudPreset(
            id: "openai", name: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!, apiStyle: .openAIChat,
            suggestedModel: nil, keyRequired: true,
            keyHint: "From platform.openai.com → API keys",
            modelHint: "A model id from OpenAI's model list, e.g. the one their docs recommend"),
        CloudPreset(
            id: "anthropic", name: "Anthropic",
            baseURL: URL(string: "https://api.anthropic.com")!, apiStyle: .anthropicMessages,
            suggestedModel: "claude-sonnet-5-5", keyRequired: true,
            keyHint: "From platform.claude.com → API keys",
            modelHint: "e.g. claude-sonnet-5-5, claude-opus-5-5"),
        CloudPreset(
            id: "openrouter", name: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiStyle: .openAIChat,
            suggestedModel: nil, keyRequired: true,
            keyHint: "From openrouter.ai → Keys",
            modelHint: "A slug from openrouter.ai/models, like vendor/model-name"),
        CloudPreset(
            id: "ollama", name: "Ollama (another machine)",
            baseURL: URL(string: "http://localhost:11434/v1")!, apiStyle: .openAIChat,
            suggestedModel: nil, keyRequired: false,
            keyHint: "Not needed for your own Ollama. Ollama's hosted service needs a key (base URL https://ollama.com/v1).",
            modelHint: "A model you have pulled, e.g. from `ollama list`"),
    ]

    public static func preset(id: String) -> CloudPreset? { all.first { $0.id == id } }

    /// What is stored in the Keychain when a preset needs no key: the request code always sends a token.
    public static let placeholderKey = "not-needed"

    public func config(model: String) -> RemoteAPIProvider.Config {
        RemoteAPIProvider.Config(
            id: id, baseURL: baseURL, modelIdentifier: model,
            capabilities: [.textGeneration, .streaming], apiStyle: apiStyle,
            envVarKey: "VIBECOCKPIT_\(id.uppercased())_TOKEN")
    }
}
