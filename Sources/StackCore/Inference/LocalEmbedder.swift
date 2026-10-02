import Foundation
import NaturalLanguage
import os

/// On-device text embeddings via macOS NaturalLanguage framework, so code search and RAG work
/// with no network and no cloud provider.
public actor LocalEmbedder: ModelProvider {

    public struct Config: Sendable, Equatable {
        public var queryPrefix: String
        public var documentPrefix: String
        public var dimension: Int

        public static let naturalLanguage = Config(
            queryPrefix: "",
            documentPrefix: "",
            dimension: 512)
    }

    public enum EmbedderError: LocalizedError {
        case dimensionMismatch(expected: Int, got: Int)
        case notAvailable
        public var errorDescription: String? {
            switch self {
            case .dimensionMismatch(let e, let g):
                return "Embedding model produced \(g)-dimensional vectors; the index expects \(e)."
            case .notAvailable:
                return "NLEmbedding for English is not available on this system."
            }
        }
    }

    public static let defaultID: ProviderID = "local:embed-nl-english"

    public nonisolated let id: ProviderID
    public nonisolated let capabilities: ProviderCapabilities = [.embedding]
    public nonisolated let dimension: Int

    private let config: Config
    private let logger = Logger(subsystem: "com.vibecockpit", category: "LocalEmbedder")

    public init(
        id: ProviderID = LocalEmbedder.defaultID,
        config: Config = .naturalLanguage
    ) {
        self.id = id
        self.config = config
        self.dimension = config.dimension
    }

    public var isInstalled: Bool { true }

    // MARK: ModelProvider

    public func generate(
        messages: [Message], tools: [ToolDefinition], options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LocalModelError.unsupportedOperation("generate")) }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await run(texts, prefix: config.documentPrefix)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await run([text], prefix: config.queryPrefix).first ?? []
    }

    public func healthCheck() async -> ProviderHealth {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else {
            return .unavailable("NLEmbedding for English is not available")
        }
        return .healthy
    }

    public func warmUp() async throws { }

    // MARK: Private

    private func run(_ texts: [String], prefix: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbedderError.notAvailable
        }
        
        let config = self.config
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        
        for text in texts {
            let input = prefix + text
            guard let vectorDouble = embedding.vector(for: input) else {
                throw EmbedderError.notAvailable // Should not happen usually, but safeguard
            }
            if vectorDouble.count != config.dimension {
                throw EmbedderError.dimensionMismatch(expected: config.dimension, got: vectorDouble.count)
            }
            vectors.append(vectorDouble.map { Float($0) })
        }
        return vectors
    }
}
