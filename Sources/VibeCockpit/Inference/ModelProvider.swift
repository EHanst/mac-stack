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
    public let inputSchema: [String: String]

    public init(name: String, description: String, inputSchema: [String: String] = [:]) {
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
    public var maxTokens: Int
    public var temperature: Double
    public var stopSequences: [String]

    public init(maxTokens: Int = 2048, temperature: Double = 0.0, stopSequences: [String] = []) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
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

    func healthCheck() async -> ProviderHealth
}

public enum InferenceTask: Sendable {
    case textGeneration
    case embedding
    case speculativeDraft
}
