import Foundation
import os

public actor EmbeddingScheduler {

    private let provider: any ModelProvider
    private let store: VectorStore
    private let batchSize: Int = 32
    private let logger = Logger(subsystem: "com.vibecockpit", category: "EmbeddingScheduler")

    private var pending: [CodeChunk] = []
    private var activeBatchTask: Task<Void, Error>?

    public init(provider: any ModelProvider, store: VectorStore,
                cpuParallelism: Int = ProcessInfo.processInfo.processorCount) {
        self.provider = provider
        self.store = store
    }

    public func schedule(_ chunks: [CodeChunk]) async {
        let needsEmbed = (try? await store.chunksNeedingEmbedding(chunks)) ?? chunks
        pending.append(contentsOf: needsEmbed)
        kickoff()
    }

    public func drain() async throws {
        // A finished batch starts the next one before its task completes, so wait until none is active.
        while let task = activeBatchTask {
            try await task.value
        }
        while !pending.isEmpty {
            kickoff()
            while let task = activeBatchTask { try await task.value }
        }
    }

    // MARK: - Private

    private func kickoff() {
        guard activeBatchTask == nil, !pending.isEmpty else { return }
        let batch = Array(pending.prefix(batchSize))
        pending.removeFirst(min(batchSize, pending.count))
        activeBatchTask = Task { [weak self] in
            guard let self else { return }
            try await self.runBatch(batch)
            await self.batchCompleted()
        }
    }

    private func batchCompleted() {
        activeBatchTask = nil
        kickoff()
    }

    private func runBatch(_ chunks: [CodeChunk]) async throws {
        let texts = chunks.map { $0.content }
        let embeddings = try await provider.embed(texts)
        for (chunk, embedding) in zip(chunks, embeddings) {
            try await store.storeEmbedding(embedding, for: chunk.id, contentHash: chunk.contentHash)
        }
        logger.debug("Embedded batch of \(chunks.count) chunks")
    }
}
