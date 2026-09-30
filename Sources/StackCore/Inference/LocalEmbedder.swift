import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import os

/// On-device text embeddings (bge-small-en-v1.5 via mlx-swift-lm), so code search and RAG work
/// with no network and no cloud provider. Chosen over Qwen3-Embedding-0.6B and nomic v1.5 in
/// the bake-off recorded in docs/plans/m0-status.md.
///
/// It shares the GPU with the chat model, so every batch goes through the same
/// `InferenceScheduler`: indexing runs at `.background`, query embedding at `.interactive`.
public actor LocalEmbedder: ModelProvider {

    public struct Config: Sendable, Equatable {
        public var queryPrefix: String
        public var documentPrefix: String
        public var maxTokens: Int
        /// Small batches keep the transient GPU peak low while a 27B model is resident.
        public var batchSize: Int
        public var layerNorm: Bool
        public var dimension: Int

        public static let bgeSmall = Config(
            queryPrefix: "Represent this sentence for searching relevant passages: ",
            documentPrefix: "", maxTokens: 512, batchSize: 8, layerNorm: false, dimension: 384)
    }

    public enum EmbedderError: LocalizedError {
        case dimensionMismatch(expected: Int, got: Int)
        public var errorDescription: String? {
            switch self {
            case .dimensionMismatch(let e, let g):
                "Embedding model produced \(g)-dimensional vectors; the index expects \(e)."
            }
        }
    }

    /// Approximate resident cost, reserved from the chat model's memory budget.
    public static let residentBytesEstimate = 300 << 20

    public static let defaultID: ProviderID = "local:embed-bge-small-en-v1.5"

    public nonisolated let id: ProviderID
    public nonisolated let capabilities: ProviderCapabilities = [.embedding]
    public nonisolated let dimension: Int

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/Models/Embedders/BAAI--bge-small-en-v1.5")
    }

    private let modelDirectory: URL
    private let config: Config
    private let scheduler: InferenceScheduler
    private var container: EmbedderModelContainer?
    private let logger = Logger(subsystem: "com.vibecockpit", category: "LocalEmbedder")

    public init(
        id: ProviderID = LocalEmbedder.defaultID,
        modelDirectory: URL = LocalEmbedder.defaultDirectory(),
        config: Config = .bgeSmall,
        scheduler: InferenceScheduler
    ) {
        self.id = id
        self.modelDirectory = modelDirectory
        self.config = config
        self.dimension = config.dimension
        self.scheduler = scheduler
    }

    public var isInstalled: Bool { Self.hasWeights(at: modelDirectory) }

    private static func hasWeights(at dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    // MARK: ModelProvider

    public func generate(
        messages: [Message], tools: [ToolDefinition], options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LocalModelError.unsupportedOperation("generate")) }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await run(texts, prefix: config.documentPrefix, priority: .background)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await run([text], prefix: config.queryPrefix, priority: .interactive).first ?? []
    }

    public func healthCheck() async -> ProviderHealth {
        guard Self.hasWeights(at: modelDirectory) else {
            return .unavailable("Embedding model not installed")
        }
        return container != nil ? .healthy : .degraded("Embedding model not yet loaded — will load on first use")
    }

    public func warmUp() async throws { _ = try await load() }

    // MARK: Private

    private func load() async throws -> EmbedderModelContainer {
        if let container { return container }
        guard Self.hasWeights(at: modelDirectory) else {
            throw LocalModelError.noWeightsFound(modelDirectory.path)
        }
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: modelDirectory, using: TransformersTokenizerLoader())
        container = loaded
        logger.info("Embedding model loaded from \(self.modelDirectory.lastPathComponent, privacy: .public)")
        return loaded
    }

    private func run(_ texts: [String], prefix: String, priority: InferenceScheduler.Priority) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await load()
        let config = self.config
        let inputs = texts.map { prefix + $0 }
        let vectors = try await scheduler.run(priority: priority) {
            await Self.embedBatches(inputs, container: container, config: config)
        }
        if let bad = vectors.first(where: { $0.count != config.dimension }) {
            throw EmbedderError.dimensionMismatch(expected: config.dimension, got: bad.count)
        }
        return vectors
    }

    private static func embedBatches(
        _ texts: [String], container: EmbedderModelContainer, config: Config
    ) async -> [[Float]] {
        await container.perform { (model: EmbeddingModel, tokenizer: MLXLMCommon.Tokenizer, pooling: Pooling) -> [[Float]] in
            let encoded = texts.map { Array(tokenizer.encode(text: $0, addSpecialTokens: true).prefix(config.maxTokens)) }
            var out = [[Float]](repeating: [], count: texts.count)
            for batch in EmbeddingBatching.plan(lengths: encoded.map(\.count), batchSize: config.batchSize) {
                let width = batch.map { encoded[$0].count }.max() ?? 1
                var tokens = [Int32](), mask = [Int32]()
                for i in batch {
                    let ids = encoded[i]
                    tokens += ids.map(Int32.init) + [Int32](repeating: 0, count: width - ids.count)
                    mask += [Int32](repeating: 1, count: ids.count) + [Int32](repeating: 0, count: width - ids.count)
                }
                let padded = MLXArray(tokens, [batch.count, width])
                let attention = MLXArray(mask, [batch.count, width]) .> 0
                let pooled = pooling(
                    model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: attention),
                    mask: attention, normalize: true, applyLayerNorm: config.layerNorm)
                pooled.eval()
                for (row, i) in batch.enumerated() { out[i] = pooled[row].asArray(Float.self) }
            }
            return out
        }
    }
}
