import Foundation
import os

/// Unified owner of ASTChunker, VectorStore, and embedding generation.
/// Single entry point for all indexing and search operations.
public actor IndexingPipeline {

    private let chunker: ASTChunker
    private let store: VectorStore
    private let registry: ModelRegistry
    private let logger = Logger(subsystem: "com.vibecockpit", category: "IndexingPipeline")

    private var embeddingScheduler: EmbeddingScheduler?
    private var watcher: WorkspaceWatcher?

    public init(store: VectorStore, registry: ModelRegistry) {
        self.chunker = ASTChunker()
        self.store = store
        self.registry = registry
    }

    public func configure(scheduler: EmbeddingScheduler) {
        self.embeddingScheduler = scheduler
    }

    public func open() async throws {
        try await store.open()
    }

    /// Index a single file. Uses content-hash cache to skip unchanged declarations.
    public func index(fileURL rawURL: URL) async throws {
        let fileURL = rawURL.canonicalPath
        let chunks = try await chunker.chunks(for: fileURL)
        try await store.syncFile(fileURL.path, chunks: chunks)
        try await embedNew(chunks: chunks)
        logger.debug("Indexed \(chunks.count) chunks from \(fileURL.lastPathComponent, privacy: .public)")
    }

    /// Re-index all Swift files in a workspace root.
    private static let reindexConcurrency = 8

    public func reindexWorkspace(_ rawRoot: URL) async throws {
        let rootURL = rawRoot.canonicalPath
        let start = Date()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let swiftURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        // At most a few files in flight: a workspace can hold thousands of Swift files.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = swiftURLs.makeIterator()
            for _ in 0..<Self.reindexConcurrency {
                guard let url = iterator.next() else { break }
                group.addTask { try await self.index(fileURL: url) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let url = iterator.next() { group.addTask { try await self.index(fileURL: url) } }
            }
        }
        try await store.pruneFiles(under: rootURL.path, keeping: Set(swiftURLs.map(\.path)))
        logger.info("Workspace indexed: \(swiftURLs.count) files in \(Date().timeIntervalSince(start), privacy: .public)s")
    }

    /// Search using hybrid RRF. Returns ranked results.
    public func search(query: String, topK: Int = 10) async throws -> [SearchResult] {
        guard let provider = await registry.preferredProvider(for: .embedding) else {
            // No embedding provider: fall back to sparse-only search
            return try await store.hybridSearch(query: query, queryEmbedding: [], topK: topK)
        }
        let queryEmbedding = try await provider.embedQuery(query)
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

    /// Forget everything stored for a deleted file (or every file under a deleted folder).
    public func remove(path: String) async throws {
        try await store.removeFiles(at: URL(fileURLWithPath: path).canonicalPath.path)
    }

    /// Keep the index current: re-index files as they change under `rootURL`, drop ones that vanish.
    public func watch(_ rawRoot: URL) {
        let rootURL = rawRoot.canonicalPath
        watcher?.stop()
        let pipeline = self
        watcher = WorkspaceWatcher(root: rootURL) { changed in
            for url in changed {
                if url.pathExtension == "swift" {
                    if FileManager.default.fileExists(atPath: url.path) { try? await pipeline.index(fileURL: url) }
                    else { try? await pipeline.remove(path: url.path) }
                } else if url.pathExtension.isEmpty, !FileManager.default.fileExists(atPath: url.path) {
                    try? await pipeline.remove(path: url.path)   // a deleted or moved folder
                }
            }
        }
    }

    public func close() async throws {
        watcher?.stop()
        watcher = nil
        try await store.close()
    }

    // MARK: - Private

    private func embedNew(chunks: [CodeChunk]) async throws {
        if let scheduler = embeddingScheduler {
            await scheduler.schedule(chunks)
            return
        }
        // Legacy path: inline batching when no scheduler is configured
        guard let provider = await registry.preferredProvider(for: .embedding) else { return }
        let needsEmbedding = try await store.chunksNeedingEmbedding(chunks)
        guard !needsEmbedding.isEmpty else { return }
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
