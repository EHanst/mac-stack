import Foundation

public typealias ProviderID = String

public struct ProviderCapabilities: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let textGeneration   = Self(rawValue: 1 << 0)
    public static let toolUse          = Self(rawValue: 1 << 1)
    public static let embedding        = Self(rawValue: 1 << 2)
    public static let streaming        = Self(rawValue: 1 << 3)
    public static let speculativeDraft = Self(rawValue: 1 << 4)
}

public struct Message: Sendable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCallID: String?

    public init(role: Role, content: String, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
    }
}

public struct ToolDefinition: Sendable, Codable {
    public let name: String
    public let description: String
    /// Full JSON Schema for the tool's arguments (`{"type":"object","properties":{…}}`).
    public let inputSchema: JSONValue

    public static let emptySchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    public init(name: String, description: String, inputSchema: JSONValue = ToolDefinition.emptySchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolCall: Sendable, Codable {
    public let id: String
    public let name: String
    public let arguments: String
}

public enum FinishReason: String, Sendable, Codable {
    case stop, length, toolUse, error
}

public enum GenerationEvent: Sendable {
    case token(String)
    case toolCall(ToolCall)
    case finished(FinishReason)
}

public struct GenerationOptions: Sendable {
    /// Maximum number of *new* tokens (not the context window). At local speeds (~10 tok/s) the old
    /// default of 64,000 would be a 1.8-hour reply, and it exceeds e.g. gpt-4o's 16,384-token output cap.
    public var maxTokens: Int
    /// Used by cloud providers. The local model uses `sampling`.
    public var temperature: Double
    public var stopSequences: [String]
    /// Local sampling. `nil` means the provider's own default (for Bonsai: the model card's
    /// non-thinking settings).
    public var sampling: SamplingParameters?

    public static let defaultMaxTokens = 8192

    public init(maxTokens: Int = GenerationOptions.defaultMaxTokens, temperature: Double = 0.0,
                stopSequences: [String] = [], sampling: SamplingParameters? = nil) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
        self.sampling = sampling
    }
}

public enum ProviderHealth: Sendable, Equatable {
    case healthy
    case degraded(String)
    case unavailable(String)
}

public protocol ModelProvider: Actor {
    nonisolated var id: ProviderID { get }
    nonisolated var capabilities: ProviderCapabilities { get }

    func generate(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error>

    func embed(_ texts: [String]) async throws -> [[Float]]

    /// Embed a search *query*. Some models want an instruction prefix on queries but not on the
    /// documents they are matched against; the default treats a query like any other text.
    func embedQuery(_ text: String) async throws -> [Float]

    func healthCheck() async -> ProviderHealth

    /// Largest prompt (in tokens) this provider can take right now, or nil if unbounded/unknown.
    func maxContextTokens() async -> Int?
}

extension ModelProvider {
    public func maxContextTokens() async -> Int? { nil }
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed([text]).first ?? []
    }
}

public enum InferenceTask: Sendable {
    case textGeneration
    case embedding
    case speculativeDraft
}
