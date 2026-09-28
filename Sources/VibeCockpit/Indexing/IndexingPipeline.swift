import Foundation
import os

/// Unified owner of ASTChunker, VectorStore, and embedding generation.
/// Single entry point for all indexing and search operations.
public actor IndexingPipeline {

    private let chunker: ASTChunker
    private let store: VectorStore
    private let registry: ModelRegistry
    private let logger = Logger(subsystem: "com.vibecockpit", category: "IndexingPipeline")

    public init(store: VectorStore, registry: ModelRegistry) {
        self.chunker = ASTChunker()
        self.store = store
        self.registry = registry
    }

    public func open() async throws {
        try await store.open()
    }

    /// Index a single file. Uses content-hash cache to skip unchanged declarations.
    public func index(fileURL: URL) async throws {
        let chunks = try await chunker.chunks(for: fileURL)
        try await store.upsertChunks(chunks)
        try await embedNew(chunks: chunks)
        logger.debug("Indexed \(chunks.count) chunks from \(fileURL.lastPathComponent, privacy: .public)")
    }

    /// Re-index all Swift files in a workspace root.
    public func reindexWorkspace(_ rootURL: URL) async throws {
        let start = Date()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let swiftURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in swiftURLs {
                group.addTask { try await self.index(fileURL: url) }
            }
            try await group.waitForAll()
        }
        logger.info("Workspace indexed: \(swiftURLs.count) files in \(Date().timeIntervalSince(start), privacy: .public)s")
    }

    /// Search using hybrid RRF. Returns ranked results.
    public func search(query: String, topK: Int = 10) async throws -> [SearchResult] {
        guard let provider = await registry.preferredProvider(for: .embedding) else {
            // No embedding provider: fall back to sparse-only search
            return try await store.hybridSearch(query: query, queryEmbedding: [], topK: topK)
        }
        let embeddings = try await provider.embed([query])
        let queryEmbedding = embeddings.first ?? []
        return try await store.hybridSearch(query: query, queryEmbedding: queryEmbedding, topK: topK)
    }

    /// Predictive prefetch: embed a file's chunks in the background when user switches to it.
    public func prefetch(fileURL: URL) async {
        do {
            let chunks = try await chunker.chunks(for: fileURL)
            try await embedNew(chunks: chunks)
        } catch {
            logger.debug("Prefetch failed for \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func close() async throws {
        try await store.close()
    }

    // MARK: - Private

    private func embedNew(chunks: [CodeChunk]) async throws {
        guard let provider = await registry.preferredProvider(for: .embedding) else { return }

        // Filter to only chunks without a cached embedding (async — filter is synchronous)
        var needsEmbedding: [CodeChunk] = []
        for chunk in chunks {
            if await store.cachedEmbedding(for: chunk.contentHash) == nil {
                needsEmbedding.append(chunk)
            }
        }
        guard !needsEmbedding.isEmpty else { return }

        // Batch in groups of 32 for throughput
        let batchSize = 32
        var offset = 0
        while offset < needsEmbedding.count {
            let batch = Array(needsEmbedding[offset..<min(offset + batchSize, needsEmbedding.count)])
            let texts = batch.map { $0.content }
            let embeddings = try await provider.embed(texts)
            for (chunk, embedding) in zip(batch, embeddings) {
                try await store.storeEmbedding(embedding, for: chunk.id, contentHash: chunk.contentHash)
            }
            offset += batchSize
        }
    }
}
