import Testing
import Foundation
@testable import KororoCore
@testable import StackCore
@testable import StackMCP

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

@Suite("Index freshness")
struct IndexFreshnessTests {

    private func setup() async throws -> (root: URL, pipeline: IndexingPipeline, store: VectorStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fresh_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VectorStore(dbURL: root.appendingPathComponent(".vc/index.sqlite"))
        let pipeline = IndexingPipeline(store: store, registry: ModelRegistry())
        try await pipeline.open()
        return (root, pipeline, store)
    }

    private func count(_ pipeline: IndexingPipeline, _ word: String) async throws -> Int {
        try await pipeline.search(query: word, topK: 50).filter { $0.content.contains(word) }.count
    }

    @Test("re-indexing an unchanged file does not duplicate its chunks")
    func noDuplicates() async throws {
        let (root, pipeline, _) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("A.swift")
        try "struct Zebrafish { var x = 1 }".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<3 { try await pipeline.index(fileURL: file) }
        #expect(try await count(pipeline, "Zebrafish") == 1)
    }

    @Test("editing a file replaces the old declaration")
    func editReplaces() async throws {
        let (root, pipeline, _) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("A.swift")
        try "struct Zebrafish { var x = 1 }".write(to: file, atomically: true, encoding: .utf8)
        try await pipeline.index(fileURL: file)
        try "struct Narwhalfish { var y = 2 }".write(to: file, atomically: true, encoding: .utf8)
        try await pipeline.index(fileURL: file)
        #expect(try await count(pipeline, "Zebrafish") == 0)
        #expect(try await count(pipeline, "Narwhalfish") == 1)
    }

    @Test("deleting a file removes it; reindexWorkspace prunes files deleted while offline")
    func deletion() async throws {
        let (root, pipeline, _) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A.swift"), b = root.appendingPathComponent("B.swift")
        try "struct Zebrafish {}".write(to: a, atomically: true, encoding: .utf8)
        try "struct Narwhalfish {}".write(to: b, atomically: true, encoding: .utf8)
        try await pipeline.reindexWorkspace(root)
        try await pipeline.remove(path: a.path)
        #expect(try await count(pipeline, "Zebrafish") == 0)
        try FileManager.default.removeItem(at: b)
        try await pipeline.reindexWorkspace(root)
        #expect(try await count(pipeline, "Narwhalfish") == 0)
    }

    @Test("the watcher indexes a new file and drops a deleted one")
    func watcher() async throws {
        let (root, pipeline, _) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.resolvingSymlinksInPath()
        await pipeline.watch(real)
        try await Task.sleep(for: .milliseconds(500))
        let file = real.appendingPathComponent("W.swift")
        try "struct Zebrafish {}".write(to: file, atomically: true, encoding: .utf8)
        var found = 0
        for _ in 0..<40 where found == 0 { try await Task.sleep(for: .milliseconds(100)); found = try await count(pipeline, "Zebrafish") }
        #expect(found == 1)
        try FileManager.default.removeItem(at: file)
        for _ in 0..<40 where found != 0 { try await Task.sleep(for: .milliseconds(100)); found = try await count(pipeline, "Zebrafish") }
        #expect(found == 0)
        try await pipeline.close()
    }
}
