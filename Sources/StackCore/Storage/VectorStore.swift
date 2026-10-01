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

private final class DBBox: @unchecked Sendable {
    var writeDB: OpaquePointer?
    var readPool: [OpaquePointer] = []

    func close() {
        if let db = writeDB { sqlite3_close_v2(db) }
        readPool.forEach { sqlite3_close_v2($0) }
        writeDB = nil
        readPool = []
    }

    deinit {
        close()
    }
}

/// SQLite-backed hybrid vector + full-text search store.
/// WAL mode + read connection pool for concurrent queries.
public actor VectorStore {

    private let dbBox = DBBox()
    private var writeDB: OpaquePointer? {
        get { dbBox.writeDB }
        set { dbBox.writeDB = newValue }
    }
    private var readPool: [OpaquePointer] {
        get { dbBox.readPool }
        set { dbBox.readPool = newValue }
    }
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
        if writeDB != nil {
            try? close()
        }
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            if let db { sqlite3_close_v2(db) }
            throw StoreError.openFailed(message)
        }
        self.writeDB = db
        do { try setUp(db: db) } catch {
            try? close()
            throw error
        }
    }

    private func setUp(db: OpaquePointer) throws {
        sqlite3_busy_timeout(db, 3000)

        // Load sqlite-vec extension
        guard sqlite3_vec_init(db, nil, nil) == SQLITE_OK else {
            throw StoreError.setupFailed("Failed to initialize sqlite-vec extension")
        }

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
                if sqlite3_vec_init(rdb, nil, nil) == SQLITE_OK {
                    readPool.append(rdb)
                } else {
                    sqlite3_close_v2(rdb)
                }
            }
        }
        logger.info("VectorStore opened at \(self.dbURL.lastPathComponent, privacy: .public)")
    }

    public func upsertChunks(_ chunks: [CodeChunk]) async throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        try exec(db: db, sql: "BEGIN IMMEDIATE;")
        do { try insertAll(chunks, db: db) } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
        try exec(db: db, sql: "COMMIT;")
        sqlite3_exec(db, "INSERT INTO chunk_fts(chunk_fts) VALUES('optimize');", nil, nil, nil)
    }

    private func insertAll(_ chunks: [CodeChunk], db: OpaquePointer) throws {
        for chunk in chunks {
            let upsertSQL = """
                INSERT OR REPLACE INTO chunks(id, file_path, decl_kind, content, content_hash)
                VALUES(?, ?, ?, ?, ?);
            """
            let stmt = try prepare(db, upsertSQL)
            defer { sqlite3_finalize(stmt) }
            let idStr = chunk.id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, chunk.filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, chunk.declarationKind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, chunk.content, -1, SQLITE_TRANSIENT)
            chunk.contentHash.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(chunk.contentHash.count), SQLITE_TRANSIENT)
            }
            try stepDone(db, stmt)

            // FTS upsert
            let ftsSQL = "INSERT OR REPLACE INTO chunk_fts(rowid, chunk_id, content) SELECT rowid, id, content FROM chunks WHERE id=?;"
            let ftsStmt = try prepare(db, ftsSQL)
            defer { sqlite3_finalize(ftsStmt) }
            sqlite3_bind_text(ftsStmt, 1, idStr, -1, SQLITE_TRANSIENT)
            try stepDone(db, ftsStmt)
        }
    }

    /// Makes the stored chunks for one file match `chunks`: new declarations are added, ones that
    /// no longer exist are removed (with their text-search and vector rows), unchanged ones are left alone.
    public func syncFile(_ path: String, chunks: [CodeChunk]) throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        try exec(db: db, sql: "BEGIN IMMEDIATE;")
        do {
            let keep = Set(chunks.map { $0.id.uuidString })
            var existing: [String: (rowid: Int64, content: String)] = [:]
            var sel: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT id, rowid, content FROM chunks WHERE file_path = ?;", -1, &sel, nil)
            sqlite3_bind_text(sel, 1, path, -1, SQLITE_TRANSIENT)
            while sqlite3_step(sel) == SQLITE_ROW {
                existing[Self.columnText(sel, 0)] = (sqlite3_column_int64(sel, 1), Self.columnText(sel, 2))
            }
            sqlite3_finalize(sel)
            for (id, row) in existing where !keep.contains(id) { deleteRow(db: db, id: id, rowid: row.rowid, content: row.content) }
            var seen = Set<String>()
            for chunk in chunks {
                let id = chunk.id.uuidString
                guard existing[id] == nil, seen.insert(id).inserted else { continue }
                insertRow(db: db, chunk: chunk)
            }
            try exec(db: db, sql: "COMMIT;")
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// Drops everything stored for a file, or for every file under it when `path` is a folder.
    public func removeFiles(at path: String) throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        try removeRows(db: db, where: "file_path = ?1 OR substr(file_path, 1, length(?1) + 1) = ?1 || '/'", bind: path)
    }

    /// Drops stored files under `root` that are not in `keep` (files deleted while nothing was watching).
    public func pruneFiles(under root: String, keeping keep: Set<String>) throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        var stored: [String] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT DISTINCT file_path FROM chunks WHERE substr(file_path, 1, length(?1) + 1) = ?1 || '/';", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, root, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW { stored.append(Self.columnText(stmt, 0)) }
        sqlite3_finalize(stmt)
        for path in stored where !keep.contains(path) { try removeFiles(at: path) }
    }

    /// The chunks that still need a model call. Chunks that already have a vector are skipped, and
    /// ones whose text was embedded before reuse the cached vector.
    public func chunksNeedingEmbedding(_ chunks: [CodeChunk]) throws -> [CodeChunk] {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        var needed: [CodeChunk] = []
        for chunk in chunks {
            let id = chunk.id.uuidString
            var has: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT 1 FROM chunk_embeddings WHERE chunk_id = ?;", -1, &has, nil)
            sqlite3_bind_text(has, 1, id, -1, SQLITE_TRANSIENT)
            let alreadyEmbedded = sqlite3_step(has) == SQLITE_ROW
            sqlite3_finalize(has)
            if alreadyEmbedded { continue }
            if let cached = cachedEmbedding(for: chunk.contentHash) {
                try storeEmbedding(cached, for: chunk.id, contentHash: chunk.contentHash)
            } else {
                needed.append(chunk)
            }
        }
        return needed
    }

    private func removeRows(db: OpaquePointer, where clause: String, bind: String) throws {
        try exec(db: db, sql: "BEGIN IMMEDIATE;")
        do {
            let sel = try prepare(db, "SELECT id, rowid, content FROM chunks WHERE \(clause);")
            defer { sqlite3_finalize(sel) }
            sqlite3_bind_text(sel, 1, bind, -1, SQLITE_TRANSIENT)
            var rows: [(String, Int64, String)] = []
            while sqlite3_step(sel) == SQLITE_ROW {
                rows.append((Self.columnText(sel, 0), sqlite3_column_int64(sel, 1), Self.columnText(sel, 2)))
            }
            for (id, rowid, content) in rows { deleteRow(db: db, id: id, rowid: rowid, content: content) }
            try exec(db: db, sql: "COMMIT;")
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func deleteRow(db: OpaquePointer, id: String, rowid: Int64, content: String) {
        var fts: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO chunk_fts(chunk_fts, rowid, chunk_id, content) VALUES('delete', ?, ?, ?);", -1, &fts, nil)
        sqlite3_bind_int64(fts, 1, rowid)
        sqlite3_bind_text(fts, 2, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(fts, 3, content, -1, SQLITE_TRANSIENT)
        sqlite3_step(fts)
        sqlite3_finalize(fts)
        for sql in ["DELETE FROM chunk_embeddings WHERE chunk_id = ?;", "DELETE FROM chunks WHERE id = ?;"] {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func insertRow(db: OpaquePointer, chunk: CodeChunk) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO chunks(id, file_path, decl_kind, content, content_hash) VALUES(?, ?, ?, ?, ?);", -1, &stmt, nil)
        let id = chunk.id.uuidString
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, chunk.filePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, chunk.declarationKind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, chunk.content, -1, SQLITE_TRANSIENT)
        chunk.contentHash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(chunk.contentHash.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        var fts: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO chunk_fts(rowid, chunk_id, content) SELECT rowid, id, content FROM chunks WHERE id = ?;", -1, &fts, nil)
        sqlite3_bind_text(fts, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(fts)
        sqlite3_finalize(fts)
    }

    public func storeEmbedding(_ embedding: [Float], for chunkID: UUID, contentHash: Data) throws {
        guard let db = writeDB else { throw StoreError.openFailed("Not open") }
        guard embedding.count == embeddingDimension else {
            throw StoreError.queryFailed("Embedding has \(embedding.count) values; the index stores \(embeddingDimension).")
        }
        let sql = "INSERT OR REPLACE INTO chunk_embeddings(chunk_id, embedding) VALUES(?, ?)"
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        let idStr = chunkID.uuidString
        sqlite3_bind_text(stmt, 1, idStr, -1, SQLITE_TRANSIENT)
        embedding.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(MemoryLayout<Float>.stride * embedding.count), SQLITE_TRANSIENT)
        }
        try stepDone(db, stmt)

        // Cache
        let cacheSQL = "INSERT OR REPLACE INTO embedding_cache(content_hash, embedding, created_at) VALUES(?, ?, ?)"
        let cacheStmt = try prepare(db, cacheSQL)
        defer { sqlite3_finalize(cacheStmt) }
        contentHash.withUnsafeBytes { ptr in
            sqlite3_bind_blob(cacheStmt, 1, ptr.baseAddress, Int32(contentHash.count), SQLITE_TRANSIENT)
        }
        embedding.withUnsafeBytes { ptr in
            sqlite3_bind_blob(cacheStmt, 2, ptr.baseAddress, Int32(MemoryLayout<Float>.stride * embedding.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(cacheStmt, 3, Int64(Date().timeIntervalSince1970))
        try stepDone(db, cacheStmt)
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
        let expectedBytes = embeddingDimension * MemoryLayout<Float>.stride
        guard Int(blobSize) == expectedBytes else { return nil }
        var floats = [Float](repeating: 0, count: embeddingDimension)
        floats.withUnsafeMutableBytes { dest in
            dest.copyMemory(from: UnsafeRawBufferPointer(start: ptr, count: expectedBytes))
        }
        return floats
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
        dbBox.close()
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
        guard let db = writeDB ?? readPool.first, FTSQuery.match(query) != nil else { return [] }
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
        guard let match = FTSQuery.match(query) else { return [] }
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
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
            let idStr = Self.columnText(stmt, 0)
            let filePath = Self.columnText(stmt, 1)
            let declKind = Self.columnText(stmt, 2)
            let content = Self.columnText(stmt, 3)
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

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func stepDone(_ db: OpaquePointer, _ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Column text, or "" for NULL (`String(cString:)` on a NULL pointer crashes).
    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
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
