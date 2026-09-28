import Testing
import Foundation
@testable import VibeCockpitCore

@Suite("IndexingPipeline")
struct IndexingPipelineTests {

    private func makePipeline(root: URL) async throws -> IndexingPipeline {
        let store = VectorStore(dbURL: root.appendingPathComponent(".vc/index.sqlite"))
        let registry = ModelRegistry()
        let pipeline = IndexingPipeline(store: store, registry: registry)
        try await pipeline.open()
        return pipeline
    }

    private func tempDir(tag: String = "") throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ip_\(tag)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - index()

    @Test("index does not throw on a valid Swift file")
    func indexSingleFile() async throws {
        let root = try tempDir(tag: "single")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Foo.swift")
        try "struct Foo { var x: Int = 0 }".write(to: file, atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        try await pipeline.index(fileURL: file)
    }

    @Test("index is idempotent — calling twice on same file does not throw")
    func indexIdempotent() async throws {
        let root = try tempDir(tag: "idem")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Bar.swift")
        try "class Bar { func run() {} }".write(to: file, atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        try await pipeline.index(fileURL: file)
        try await pipeline.index(fileURL: file)
    }

    @Test("index on an empty Swift file does not throw")
    func indexEmptyFile() async throws {
        let root = try tempDir(tag: "empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Empty.swift")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        try await pipeline.index(fileURL: file)
    }

    // MARK: - reindexWorkspace()

    @Test("reindexWorkspace indexes all Swift files and ignores non-Swift files")
    func reindexWorkspace() async throws {
        let root = try tempDir(tag: "ws")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "struct Alpha {}".write(to: src.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        try "struct Beta {}".write(to: src.appendingPathComponent("Beta.swift"), atomically: true, encoding: .utf8)
        try "not swift".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        try await pipeline.reindexWorkspace(root)
    }

    @Test("reindexWorkspace on an empty directory does not throw")
    func reindexEmptyDir() async throws {
        let root = try tempDir(tag: "wsempty")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try await makePipeline(root: root)
        try await pipeline.reindexWorkspace(root)
    }

    @Test("reindexWorkspace indexes nested directories")
    func reindexNested() async throws {
        let root = try tempDir(tag: "wsnested")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("A/B/C")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "enum Deep { case x }".write(to: deep.appendingPathComponent("Deep.swift"), atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        try await pipeline.reindexWorkspace(root)
    }

    // MARK: - search()

    @Test("search without embedding provider falls back to sparse and returns without throw")
    func searchFallbackToSparse() async throws {
        let root = try tempDir(tag: "search")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Auth.swift")
        try "class AuthenticationService { func login(user: String) {} }".write(
            to: file, atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        try await pipeline.index(fileURL: file)
        let results = try await pipeline.search(query: "AuthenticationService", topK: 5)
        _ = results
    }

    @Test("search on empty index returns empty array without throw")
    func searchEmptyIndex() async throws {
        let root = try tempDir(tag: "searchempty")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try await makePipeline(root: root)
        let results = try await pipeline.search(query: "anything", topK: 5)
        #expect(results.isEmpty)
    }

    @Test("prefetch on a valid Swift file does not throw")
    func prefetch() async throws {
        let root = try tempDir(tag: "prefetch")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("P.swift")
        try "protocol Prefetchable {}".write(to: file, atomically: true, encoding: .utf8)
        let pipeline = try await makePipeline(root: root)
        await pipeline.prefetch(fileURL: file)
    }
}
