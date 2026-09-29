import Foundation
import CSQLiteVec
import os
import SQLite3

// SQLITE_TRANSIENT is a C macro that Swift doesn't import directly.
// It tells SQLite to make its own copy of the data immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public struct SearchResult: Sendable, Identifiable {
    public let id: UUID
    public let chunkID: UUID
    public let filePath: String
    public let declarationKind: String
    public let content: String
    public let score: Double
    public let rank: Int

    public init(id: UUID = UUID(), chunkID: UUID, filePath: String,
                declarationKind: String, content: String, score: Double, rank: Int) {
        self.id = id
        self.chunkID = chunkID
        self.filePath = filePath
        self.declarationKind = declarationKind
        self.content = content
        self.score = score
        self.rank = rank
    }
}

/// SQLite-backed hybrid vector + full-text search store.
/// WAL mode + read connection pool for concurrent queries.
public actor VectorStore {

    private var writeDB: OpaquePointer?
    private var readPool: [OpaquePointer] = []
    private let readPoolSize = 4
    private let dbURL: URL
    private let embeddingDimension: Int
    private let logger = Logger(subsystem: "com.vibecockpit", category: "VectorStore")

    // LRU query embedding cache (in-memory, evicts oldest when over capacity)
    private var queryCache: [(key: String, value: [Float])] = []
    private let queryCacheCapacity = 128

    public enum StoreError: LocalizedError {
        case openFailed(String)
        case setupFailed(String)
        case queryFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let msg): "Failed to open database: \(msg)"
            case .setupFailed(let msg): "Database setup failed: \(msg)"
            case .queryFailed(let msg): "Query failed: \(msg)"
            }
        }
    }

    public init(dbURL: URL, embeddingDimension: Int = 384) {
        self.dbURL = dbURL
        self.embeddingDimension = embeddingDimension
    }

    public func open() throws {
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        self.writeDB = db

        sqlite3_busy_timeout(db, 3000)

        // Load sqlite-vec extension
        sqlite3_vec_init(db, nil, nil)

        try exec(db: db, sql: "PRAGMA journal_mode=WAL;")
        try exec(db: db, sql: "PRAGMA synchronous=NORMAL;")
        try exec(db: db, sql: "PRAGMA foreign_keys=ON;")
        try exec(db: db, sql: "PRAGMA wal_autocheckpoint=1000;")

        try createSchema(db: db)

        // Open read-only connections for the pool
        for _ in 0..<readPoolSize {
            var rdb: OpaquePointer?
            let rflags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(dbURL.path, &rdb, rflags, nil) == SQLITE_OK, let rdb {
                sqlite3_busy_timeout(rdb, 3000)
                sqlite3_exec(rdb, "PRAGMA mmap_size=268435456;", nil, nil, nil)
                sqlite3_vec_init(rdb, nil, nil)
                readPool.append(rdb)
            }
        }
        logger.info("VectorStore opened at \(self.dbURL.lastPathComponent, privacy: .public)")
    }

    public func upsertChunks(_ chunks: [CodeChunk]) async throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        try exec(db: db, sql: "BEGIN IMMEDIATE;")
        defer {
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            sqlite3_exec(db, "INSERT INTO chunk_fts(chunk_fts) VALUES('optimize');", nil, nil, nil)
        }

        for chunk in chunks {
            let upsertSQL = """
                INSERT OR REPLACE INTO chunks(id, file_path, decl_kind, content, content_hash)
                VALUES(?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            let idStr = chunk.id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, chunk.filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, chunk.declarationKind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, chunk.content, -1, SQLITE_TRANSIENT)
            chunk.contentHash.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(chunk.contentHash.count), SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)

            // FTS upsert
            let ftsSQL = "INSERT OR REPLACE INTO chunk_fts(rowid, chunk_id, content) SELECT rowid, id, content FROM chunks WHERE id=?;"
            var ftsStmt: OpaquePointer?
            sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil)
            defer { sqlite3_finalize(ftsStmt) }
            sqlite3_bind_text(ftsStmt, 1, idStr, -1, SQLITE_TRANSIENT)
            sqlite3_step(ftsStmt)
        }
    }

    public func storeEmbedding(_ embedding: [Float], for chunkID: UUID, contentHash: Data) throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        let sql = "INSERT OR REPLACE INTO chunk_embeddings(chunk_id, embedding) VALUES(?, ?)"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let idStr = chunkID.uuidString
        sqlite3_bind_text(stmt, 1, idStr, -1, SQLITE_TRANSIENT)
        embedding.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(MemoryLayout<Float>.stride * embedding.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)

        // Cache
        let cacheSQL = "INSERT OR REPLACE INTO embedding_cache(content_hash, embedding, created_at) VALUES(?, ?, ?)"
        var cacheStmt: OpaquePointer?
        sqlite3_prepare_v2(db, cacheSQL, -1, &cacheStmt, nil)
        defer { sqlite3_finalize(cacheStmt) }
        contentHash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(cacheStmt, 1, ptr.baseAddress, Int32(contentHash.count), SQLITE_TRANSIENT)
        }
        embedding.withUnsafeBytes { ptr in
            sqlite3_bind_blob(cacheStmt, 2, ptr.baseAddress, Int32(MemoryLayout<Float>.stride * embedding.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(cacheStmt, 3, Int64(Date().timeIntervalSince1970))
        sqlite3_step(cacheStmt)
    }

    public func cachedEmbedding(for contentHash: Data) -> [Float]? {
        guard let db = readPool.first else { return nil }
        let sql = "SELECT embedding FROM embedding_cache WHERE content_hash=?"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        contentHash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(contentHash.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let blobPtr = sqlite3_column_blob(stmt, 0)
        let blobSize = sqlite3_column_bytes(stmt, 0)
        guard let ptr = blobPtr else { return nil }
        let count = Int(blobSize) / MemoryLayout<Float>.stride
        return Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
    }

    public func cacheQueryEmbedding(_ embedding: [Float], for query: String) {
        if let idx = queryCache.firstIndex(where: { $0.key == query }) {
            queryCache.remove(at: idx)
        }
        queryCache.append((key: query, value: embedding))
        if queryCache.count > queryCacheCapacity {
            queryCache.removeFirst()
        }
    }

    public func cachedQueryEmbedding(for query: String) -> [Float]? {
        guard let idx = queryCache.firstIndex(where: { $0.key == query }) else { return nil }
        let entry = queryCache.remove(at: idx)
        queryCache.append(entry)
        return entry.value
    }

    public func hybridSearch(
        query: String,
        queryEmbedding: [Float],
        topK: Int = 10
    ) async throws -> [SearchResult] {
        let dense = try denseSearch(embedding: queryEmbedding, topK: topK)
        let sparse = try sparseSearch(query: query, topK: topK)
        return reciprocalRankFusion(dense: dense, sparse: sparse, k: 60).prefix(topK).map { $0 }
    }

    public func checkpoint() throws {
        guard let db = writeDB else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    public func close() throws {
        if let db = writeDB { sqlite3_close(db) }
        readPool.forEach { sqlite3_close($0) }
        writeDB = nil
        readPool = []
    }

    // MARK: - Private

    private func denseSearch(embedding: [Float], topK: Int) throws -> [SearchResult] {
        guard let db = writeDB ?? readPool.first else { return [] }
        let vecSQL = """
            SELECT c.id, c.file_path, c.decl_kind, c.content,
                   vec_distance_cosine(e.embedding, ?) AS distance
            FROM chunk_embeddings e
            JOIN chunks c ON c.id = e.chunk_id
            ORDER BY distance ASC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, vecSQL, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        embedding.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(MemoryLayout<Float>.stride * embedding.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(stmt, 2, Int32(topK))
        return rows(from: stmt)
    }

    private func sparseSearch(query: String, topK: Int) throws -> [SearchResult] {
        guard let db = writeDB ?? readPool.first else { return [] }
        let ftsSQL = """
            SELECT c.id, c.file_path, c.decl_kind, c.content,
                   bm25(chunk_fts) AS score
            FROM chunk_fts
            JOIN chunks c ON c.rowid = chunk_fts.rowid
            WHERE chunk_fts MATCH ?
            ORDER BY score ASC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, ftsSQL, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let escapedQuery = query.replacingOccurrences(of: "\"", with: "\"\"")
        sqlite3_bind_text(stmt, 1, "\"\(escapedQuery)\"", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(topK))
        return rows(from: stmt)
    }

    public func reciprocalRankFusion(
        dense: [SearchResult],
        sparse: [SearchResult],
        k: Int = 60
    ) -> [SearchResult] {
        var scores: [UUID: Double] = [:]
        var best: [UUID: SearchResult] = [:]
        for (rank, result) in dense.enumerated() {
            scores[result.chunkID, default: 0] += 1.0 / Double(k + rank + 1)
            best[result.chunkID] = result
        }
        for (rank, result) in sparse.enumerated() {
            scores[result.chunkID, default: 0] += 1.0 / Double(k + rank + 1)
            if best[result.chunkID] == nil { best[result.chunkID] = result }
        }
        return scores.sorted { $0.value > $1.value }.enumerated().compactMap { idx, kv in
            guard var r = best[kv.key] else { return nil }
            return SearchResult(chunkID: r.chunkID, filePath: r.filePath,
                                declarationKind: r.declarationKind, content: r.content,
                                score: kv.value, rank: idx)
        }
    }

    private func rows(from stmt: OpaquePointer?) -> [SearchResult] {
        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let filePath = String(cString: sqlite3_column_text(stmt, 1))
            let declKind = String(cString: sqlite3_column_text(stmt, 2))
            let content = String(cString: sqlite3_column_text(stmt, 3))
            let score = sqlite3_column_double(stmt, 4)
            if let id = UUID(uuidString: idStr) {
                results.append(SearchResult(chunkID: id, filePath: filePath,
                                            declarationKind: declKind, content: content,
                                            score: score, rank: results.count))
            }
        }
        return results
    }

    private func createSchema(db: OpaquePointer) throws {
        let schema = """
            CREATE TABLE IF NOT EXISTS chunks(
                id TEXT PRIMARY KEY,
                file_path TEXT NOT NULL,
                decl_kind TEXT NOT NULL,
                content TEXT NOT NULL,
                content_hash BLOB NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
                chunk_id UNINDEXED, content, content='chunks', content_rowid='rowid'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_embeddings USING vec0(
                chunk_id TEXT PRIMARY KEY,
                embedding FLOAT[\(embeddingDimension)]
            );
            CREATE TABLE IF NOT EXISTS embedding_cache(
                content_hash BLOB PRIMARY KEY,
                embedding BLOB NOT NULL,
                created_at INTEGER NOT NULL
            );
        """
        try exec(db: db, sql: schema)
    }

    @discardableResult
    private func exec(db: OpaquePointer, sql: String) throws -> Int32 {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw StoreError.setupFailed(msg)
        }
        return rc
    }
}
