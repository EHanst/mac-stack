import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore
@testable import StackMCP

@Suite("VectorStore")
struct VectorStoreTests {

    private func makeStore() async throws -> (VectorStore, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_test_\(UUID().uuidString)/index.sqlite")
        let store = VectorStore(dbURL: tmp)
        try await store.open()
        return (store, tmp)
    }

    @Test("upsertChunks and cachedEmbedding round-trip")
    func upsertAndCache() async throws {
        let (store, tmp) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let chunk = CodeChunk(filePath: "/ws/A.swift", declarationKind: "struct",
                              startLine: 1, endLine: 2, content: "struct A {}")
        try await store.upsertChunks([chunk])
        try await store.storeEmbedding([Float](repeating: 0.1, count: 384),
                                        for: chunk.id, contentHash: chunk.contentHash)
        let cached = await store.cachedEmbedding(for: chunk.contentHash)
        #expect(cached != nil)
        #expect(cached?.count == 384)
    }

    @Test("query embedding cache LRU eviction at capacity 128")
    func queryEmbeddingCacheEviction() async throws {
        let (store, tmp) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        for i in 0..<130 {
            let embedding = [Float](repeating: Float(i), count: 384)
            await store.cacheQueryEmbedding(embedding, for: "query \(i)")
        }
        let evicted = await store.cachedQueryEmbedding(for: "query 0")
        #expect(evicted == nil)
        let recent = await store.cachedQueryEmbedding(for: "query 129")
        #expect(recent != nil)
    }

    @Test("hybridSearch returns matching result after upsert")
    func hybridSearchFindsUpsertedChunk() async throws {
        let (store, tmp) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let chunk = CodeChunk(filePath: "/ws/Auth.swift", declarationKind: "class",
                              startLine: 1, endLine: 8,
                              content: "class AuthenticationManager { func login(user: String) {} }")
        try await store.upsertChunks([chunk])
        let results = try await store.hybridSearch(
            query: "AuthenticationManager", queryEmbedding: [], topK: 5)
        #expect(results.contains { $0.filePath == "/ws/Auth.swift" })
    }

    @Test("hybridSearch returns empty array when store is empty")
    func hybridSearchEmptyStore() async throws {
        let (store, tmp) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let results = try await store.hybridSearch(query: "anything", queryEmbedding: [], topK: 5)
        #expect(results.isEmpty)
    }

    @Test("hybridSearch topK caps the result count")
    func hybridSearchTopKCap() async throws {
        let (store, tmp) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let chunks = (0..<10).map { i in
            CodeChunk(filePath: "/ws/F\(i).swift", declarationKind: "func",
                      startLine: 1, endLine: 2, content: "func search\(i)() -> Int { \(i) }")
        }
        try await store.upsertChunks(chunks)
        let results = try await store.hybridSearch(query: "search", queryEmbedding: [], topK: 3)
        #expect(results.count <= 3)
    }

    @Test("no SQLITE_BUSY during concurrent reads and write")
    func noBusyErrors() async throws {
        let (store, tmp) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let chunks = (0..<10).map { i in
            CodeChunk(filePath: "/ws/F\(i).swift", declarationKind: "func",
                      startLine: 1, endLine: 2, content: "func f\(i)() {}")
        }
        try await store.upsertChunks(chunks)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for chunk in chunks {
                    _ = await store.cachedEmbedding(for: chunk.contentHash)
                }
            }
            group.addTask {
                let extraChunks = (10..<20).map { i in
                    CodeChunk(filePath: "/ws/G\(i).swift", declarationKind: "func",
                              startLine: 1, endLine: 2, content: "func g\(i)() {}")
                }
                try await store.upsertChunks(extraChunks)
            }
            try await group.waitForAll()
        }
    }
}
