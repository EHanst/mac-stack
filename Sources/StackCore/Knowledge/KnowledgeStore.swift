import Foundation
import CSQLiteVec
import Crypto
import os
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

private func kText(_ s: OpaquePointer, _ i: Int32) -> String {
    sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
}
private func kOptText(_ s: OpaquePointer, _ i: Int32) -> String? {
    sqlite3_column_type(s, i) == SQLITE_NULL ? nil : kText(s, i)
}

extension Array where Element == Float {
    var knowledgeBlob: Data { withUnsafeBufferPointer { Data(buffer: $0) } }
}

public struct KnowledgePackInfo: Codable, Sendable, Equatable {
    public var id: String, name: String, version: Int, license: String, attribution: String
    public init(id: String, name: String, version: Int, license: String, attribution: String) {
        self.id = id; self.name = name; self.version = version; self.license = license; self.attribution = attribution
    }
}

public struct KnowledgePackSummary: Sendable, Equatable {
    public var info: KnowledgePackInfo
    public var count: Int
    /// False when every entry of the pack is disabled.
    public var enabled: Bool
}

/// The sidecar model's own lasting knowledge: prompt-engineering notes and the user's accepted briefs.
/// A separate file and a separate type from `VectorStore`, so the code index and this never mix.
public actor KnowledgeStore {
    private enum Bind { case text(String), int(Int64), double(Double), blob(Data), null }

    static let schemaVersion = 1
    private static let entryColumns = "id, kind, target, pack, text, meta_json, weight, enabled, created"

    private let dbURL: URL
    private let dimension: Int
    private let embedder: KnowledgeEmbedder?
    private var db: OpaquePointer?
    private let logger = Logger(subsystem: "com.vibecockpit", category: "KnowledgeStore")
    /// True when the file was unreadable or from another schema and was rebuilt empty.
    public private(set) var didReset = false
    /// Set when a read finds the file corrupt after a successful open; the next `open()` rebuilds it.
    private var needsReset = false
    private var openedOK = false
    /// Entries the embedder returned a wrong-sized vector for; not retried this session.
    private var unembeddable: Set<String> = []
    private var reembedding = false

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/Knowledge/knowledge.db")
    }

    public init(dbURL: URL, dimension: Int = 384, embedder: KnowledgeEmbedder? = nil) {
        self.dbURL = dbURL; self.dimension = dimension; self.embedder = embedder
    }

    // MARK: Open / close

    public func open() throws {
        if db != nil && !needsReset { return }
        if needsReset { rebuild() }
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try openOnce()
        } catch KnowledgeError.corrupt {
            rebuild()
            try openOnce()
        }
    }

    /// Drops an unreadable file so the next open starts empty, and remembers to say so.
    private func rebuild() {
        logger.error("knowledge store unreadable; rebuilding")
        closeHandle()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
        didReset = true
        needsReset = false
    }

    public func close() { closeHandle() }

    private func closeHandle() {
        if let db { sqlite3_close(db) }
        db = nil
        openedOK = false
    }

    private func openOnce() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw KnowledgeError.openFailed(msg)
        }
        db = handle
        do {
            sqlite3_busy_timeout(handle, 3000)
            sqlite3_vec_init(handle, nil, nil)
            try run("PRAGMA journal_mode=WAL;")
            try run("PRAGMA synchronous=NORMAL;")
            let version = try query("PRAGMA user_version;") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            // A file from a newer build is left alone (this build just can't use it); only an unknown older one is rebuilt.
            if version > Self.schemaVersion { throw KnowledgeError.openFailed("The saved learning data was made by a newer version of the app.") }
            if version != 0 && version != Self.schemaVersion { throw KnowledgeError.corrupt }
            try exec("""
                CREATE TABLE IF NOT EXISTS entries(
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, target TEXT, pack TEXT, text TEXT NOT NULL,
                    meta_json TEXT NOT NULL DEFAULT '{}', content_hash TEXT NOT NULL UNIQUE,
                    weight REAL NOT NULL DEFAULT 1.0, enabled INTEGER NOT NULL DEFAULT 1, created REAL NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(text);
                CREATE TABLE IF NOT EXISTS signals(
                    id TEXT PRIMARY KEY, entry_id TEXT NOT NULL, outcome TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS packs(
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL,
                    license TEXT NOT NULL, attribution TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            // A different embedder dimension invalidates every stored vector; the entries stay and
            // `reembedMissing()` refills the table.
            let stored = try query("SELECT value FROM meta WHERE key='dimension';") { kText($0, 0) }.first.flatMap(Int.init)
            if let stored, stored != dimension { try exec("DROP TABLE IF EXISTS entries_vec;") }
            try exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS entries_vec USING vec0(
                    entry_id TEXT PRIMARY KEY, embedding FLOAT[\(dimension)]);
            """)
            try run("INSERT OR REPLACE INTO meta(key, value) VALUES('dimension', ?);", [.text(String(dimension))])
            try exec("PRAGMA user_version = \(Self.schemaVersion);")
            openedOK = true
        } catch {
            closeHandle()
            throw error
        }
    }

    // MARK: Add

    public static func contentHash(pack: String?, kind: KnowledgeKind, target: String?, text: String) -> String {
        let material = "\(pack ?? "")|\(kind.rawValue)|\(target ?? "")|\(text)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores new entries (duplicates by content are skipped) and embeds them. If the embedder is
    /// unavailable the rows are kept and found by text search; `reembedMissing()` fills the vectors later.
    @discardableResult
    public func addAll(_ entries: [KnowledgeEntry]) async throws -> Int {
        try open()
        var fresh: [(id: String, text: String)] = []
        try exec("BEGIN IMMEDIATE;")
        do {
            for var e in entries {
                e.text = String(e.text.prefix(KnowledgeLimits.maxTextChars))
                guard !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let hash = Self.contentHash(pack: e.pack, kind: e.kind, target: e.target, text: e.text)
                if try query("SELECT 1 FROM entries WHERE content_hash=?;", [.text(hash)], { _ in 1 }).first != nil { continue }
                let meta = (try? JSONEncoder().encode(e.meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try run("""
                    INSERT INTO entries(id, kind, target, pack, text, meta_json, content_hash, weight, enabled, created)
                    VALUES(?,?,?,?,?,?,?,?,?,?);
                    """, [.text(e.id), .text(e.kind.rawValue), e.target.map(Bind.text) ?? .null,
                          e.pack.map(Bind.text) ?? .null, .text(e.text), .text(meta), .text(hash),
                          .double(min(max(e.weight, KnowledgeLimits.weightRange.lowerBound), KnowledgeLimits.weightRange.upperBound)),
                          .int(e.enabled ? 1 : 0), .double(e.created.timeIntervalSince1970)])
                try run("INSERT INTO entries_fts(rowid, text) SELECT rowid, text FROM entries WHERE id=?;", [.text(e.id)])
                fresh.append((e.id, e.text))
            }
            try exec("COMMIT;")
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
        await embed(fresh)
        return fresh.count
    }

    private func embed(_ rows: [(id: String, text: String)], batch: Int = 16) async {
        guard let embedder, !rows.isEmpty else { return }
        for start in stride(from: 0, to: rows.count, by: batch) {
            let slice = Array(rows[start..<min(start + batch, rows.count)])
            guard let vectors = try? await embedder.documents(slice.map(\.text)), vectors.count == slice.count else { continue }
            for (row, v) in zip(slice, vectors) {
                if v.count == dimension { try? storeVector(v, id: row.id) } else { unembeddable.insert(row.id) }
            }
        }
    }

    private func storeVector(_ v: [Float], id: String) throws {
        // The entry may have been deleted while the embedder was working (this actor re-enters at `await`).
        guard try query("SELECT 1 FROM entries WHERE id = ?;", [.text(id)], { _ in 1 }).first != nil else { return }
        try run("DELETE FROM entries_vec WHERE entry_id = ?;", [.text(id)])
        try run("INSERT INTO entries_vec(entry_id, embedding) VALUES(?, ?);", [.text(id), .blob(v.knowledgeBlob)])
    }

    // MARK: Read

    private static func entry(_ s: OpaquePointer) -> KnowledgeEntry {
        KnowledgeEntry(
            id: kText(s, 0), kind: KnowledgeKind(rawValue: kText(s, 1)) ?? .technique,
            target: kOptText(s, 2), pack: kOptText(s, 3), text: kText(s, 4),
            meta: (try? JSONDecoder().decode([String: String].self, from: Data(kText(s, 5).utf8))) ?? [:],
            weight: sqlite3_column_double(s, 6), enabled: sqlite3_column_int(s, 7) != 0,
            created: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)))
    }

    public func entry(id: String) throws -> KnowledgeEntry? {
        try open()
        return try query("SELECT \(Self.entryColumns) FROM entries WHERE id=?;", [.text(id)], Self.entry).first
    }

    public func all(kind: KnowledgeKind? = nil, limit: Int = 500) throws -> [KnowledgeEntry] {
        try open()
        if let kind {
            return try query("SELECT \(Self.entryColumns) FROM entries WHERE kind=? ORDER BY created DESC, id LIMIT ?;",
                             [.text(kind.rawValue), .int(Int64(limit))], Self.entry)
        }
        return try query("SELECT \(Self.entryColumns) FROM entries ORDER BY created DESC, id LIMIT ?;",
                         [.int(Int64(limit))], Self.entry)
    }

    public func counts() throws -> [KnowledgeKind: Int] {
        try open()
        var out: [KnowledgeKind: Int] = [:]
        for (k, n) in try query("SELECT kind, count(*) FROM entries GROUP BY kind;", [], { (kText($0, 0), Int(sqlite3_column_int($0, 1))) }) {
            if let kind = KnowledgeKind(rawValue: k) { out[kind] = n }
        }
        return out
    }

    public func embeddedCount() throws -> Int {
        try open()
        return try query("SELECT count(*) FROM entries_vec;") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    // MARK: Change

    public func setEnabled(_ on: Bool, id: String) throws {
        try open()
        try run("UPDATE entries SET enabled=? WHERE id=?;", [.int(on ? 1 : 0), .text(id)])
    }

    public func delete(ids: [String]) throws {
        try open()
        try exec("BEGIN IMMEDIATE;")
        do {
            for id in ids { try removeRows(id: id) }
            try exec("COMMIT;")
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// Removes a brief's accepted exemplars other than `keep`, so the latest version stands alone.
    public func deleteExemplars(briefID: String, except keep: String) throws {
        try open()
        let ids = try query("""
            SELECT id FROM entries WHERE kind = 'exemplar' AND id != ? AND json_extract(meta_json, '$.briefID') = ?;
            """, [.text(keep), .text(briefID)]) { kText($0, 0) }
        if !ids.isEmpty { try delete(ids: ids) }
    }

    /// Removes the user's own history (entries with no pack). Pack entries stay.
    public func wipeHistory() throws {
        try open()
        try delete(ids: try query("SELECT id FROM entries WHERE pack IS NULL;") { kText($0, 0) })
    }

    public func wipeAll() throws {
        try open()
        try delete(ids: try query("SELECT id FROM entries;") { kText($0, 0) })
        try run("DELETE FROM packs;")
    }

    private func removeRows(id: String) throws {
        try run("DELETE FROM entries_fts WHERE rowid = (SELECT rowid FROM entries WHERE id=?);", [.text(id)])
        try run("DELETE FROM entries_vec WHERE entry_id = ?;", [.text(id)])
        try run("DELETE FROM signals WHERE entry_id = ?;", [.text(id)])
        try run("DELETE FROM entries WHERE id = ?;", [.text(id)])
    }

    // MARK: Search

    public func search(query text: String, target: String?, k: Int = 20) async -> [KnowledgeHit] {
        guard (try? open()) != nil else { return [] }
        // Nothing to find: skip the embedding a query would cost.
        guard (try? query("SELECT 1 FROM entries WHERE enabled = 1 LIMIT 1;", [], { _ in 1 }))?.first != nil else { return [] }
        let filter = "e.enabled = 1 AND (e.target IS NULL OR e.target = ?)"
        let targetBind = Bind.text(target ?? "")
        var sparse: [String] = []
        if let match = FTSQuery.match(text) {
            sparse = (try? query("""
                SELECT e.id FROM entries_fts f JOIN entries e ON e.rowid = f.rowid
                WHERE entries_fts MATCH ? AND \(filter) ORDER BY bm25(entries_fts) LIMIT ?;
                """, [.text(match), targetBind, .int(Int64(k))]) { kText($0, 0) }) ?? []
        }
        var dense: [String] = []
        if let embedder, let q = try? await embedder.query(text), q.count == dimension {
            dense = (try? query("""
                SELECT e.id FROM entries_vec v JOIN entries e ON e.id = v.entry_id
                WHERE \(filter) ORDER BY vec_distance_cosine(v.embedding, ?) LIMIT ?;
                """, [targetBind, .blob(q.knowledgeBlob), .int(Int64(k))]) { kText($0, 0) }) ?? []
        }
        var hits: [KnowledgeHit] = []
        for (id, score) in RankFusion.fuse([dense, sparse]).prefix(k) {
            if let e = try? entry(id: id) { hits.append(KnowledgeHit(entry: e, score: score)) }
        }
        return hits
    }

    /// Embeds entries that have no vector (the embedder was unavailable, or the dimension changed).
    @discardableResult
    public func reembedMissing(batch: Int = 16) async -> Int {
        guard embedder != nil, !reembedding, (try? open()) != nil else { return 0 }
        reembedding = true
        defer { reembedding = false }
        let rows = ((try? query("""
            SELECT id, text FROM entries WHERE id NOT IN (SELECT entry_id FROM entries_vec) LIMIT 500;
            """) { (id: kText($0, 0), text: kText($0, 1)) }) ?? []).filter { !unembeddable.contains($0.id) }
        guard !rows.isEmpty else { return 0 }
        let before = (try? embeddedCount()) ?? 0
        await embed(rows, batch: batch)
        return max(0, ((try? embeddedCount()) ?? 0) - before)
    }

    // MARK: Signals

    public func applySignal(ids: [String], outcome: SignalOutcome) throws {
        try open()
        let factor: Double = switch outcome { case .accepted: 1.15; case .edited: 1.0; case .rejected: 0.8 }
        let range = KnowledgeLimits.weightRange
        try exec("BEGIN IMMEDIATE;")
        do {
            for id in ids {
                try run("""
                    INSERT INTO signals(id, entry_id, outcome, created)
                    SELECT ?, id, ?, ? FROM entries WHERE id = ?;
                    """, [.text(UUID().uuidString), .text(outcome.rawValue), .double(Date().timeIntervalSince1970), .text(id)])
                try run("UPDATE entries SET weight = MIN(?, MAX(?, weight * ?)) WHERE id = ?;",
                        [.double(range.upperBound), .double(range.lowerBound), .double(factor), .text(id)])
            }
            try exec("COMMIT;")
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    // MARK: Packs

    public func registerPack(_ info: KnowledgePackInfo) throws {
        try open()
        try run("INSERT OR REPLACE INTO packs(id, name, version, license, attribution) VALUES(?,?,?,?,?);",
                [.text(info.id), .text(info.name), .int(Int64(info.version)), .text(info.license), .text(info.attribution)])
    }

    public func packSummaries() throws -> [KnowledgePackSummary] {
        try open()
        return try query("""
            SELECT p.id, p.name, p.version, p.license, p.attribution,
                   (SELECT count(*) FROM entries e WHERE e.pack = p.id),
                   (SELECT count(*) FROM entries e WHERE e.pack = p.id AND e.enabled = 1)
            FROM packs p ORDER BY p.name;
            """) { s in
            let count = Int(sqlite3_column_int(s, 5)), on = Int(sqlite3_column_int(s, 6))
            return KnowledgePackSummary(
                info: KnowledgePackInfo(id: kText(s, 0), name: kText(s, 1), version: Int(sqlite3_column_int(s, 2)),
                                        license: kText(s, 3), attribution: kText(s, 4)),
                count: count, enabled: count == 0 || on > 0)
        }
    }

    public func packEntryIDs(pack: String) throws -> Set<String> {
        try open()
        return Set(try query("SELECT id FROM entries WHERE pack = ?;", [.text(pack)]) { kText($0, 0) })
    }

    public func setPackEnabled(_ on: Bool, pack: String) throws {
        try open()
        try run("UPDATE entries SET enabled = ? WHERE pack = ?;", [.int(on ? 1 : 0), .text(pack)])
    }

    @discardableResult
    public func removePack(_ id: String) throws -> Int {
        try open()
        let ids = try packEntryIDs(pack: id)
        try delete(ids: Array(ids))
        try run("DELETE FROM packs WHERE id = ?;", [.text(id)])
        return ids.count
    }

    // MARK: SQLite plumbing

    private func failure() -> KnowledgeError {
        let code = sqlite3_errcode(db)
        if code == SQLITE_NOTADB || code == SQLITE_CORRUPT {
            if openedOK { needsReset = true }     // found after a good open: rebuild on the next call
            return .corrupt
        }
        return .queryFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw KnowledgeError.openFailed("Not open") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, &err, nil) != SQLITE_OK {
            sqlite3_free(err)
            throw failure()
        }
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        guard let db else { throw KnowledgeError.openFailed("Not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, SQLITE_TRANSIENT)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .double(let v): sqlite3_bind_double(stmt, n, v)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Bind] = []) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw failure() }
    }

    private func query<T>(_ sql: String, _ binds: [Bind] = [], _ map: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(map(stmt)) } else if rc == SQLITE_DONE { break } else { throw failure() }
        }
        return out
    }
}
