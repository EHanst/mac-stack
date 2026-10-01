import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore
@testable import StackMCP

// Tests that load the real model live in `KokoroEmbedBench --self-test`: MLX finds its Metal library
// next to the executable, which is not the case inside `swift test`'s helper process.

@Suite("EmbeddingBatching")
struct EmbeddingBatchingTests {
    @Test("batches are length-sorted, capped, and cover every index exactly once")
    func plan() {
        let lengths = [50, 5, 30, 5, 100, 1, 70]
        let batches = EmbeddingBatching.plan(lengths: lengths, batchSize: 3)
        #expect(batches.allSatisfy { $0.count <= 3 && !$0.isEmpty })
        #expect(batches.flatMap { $0 }.sorted() == Array(lengths.indices))
        let flattenedLengths = batches.flatMap { $0 }.map { lengths[$0] }
        #expect(flattenedLengths == flattenedLengths.sorted())      // shortest first → minimal padding
    }

    @Test("empty input and zero batch size produce no batches")
    func edges() {
        #expect(EmbeddingBatching.plan(lengths: [], batchSize: 4).isEmpty)
        #expect(EmbeddingBatching.plan(lengths: [1, 2], batchSize: 0).isEmpty)
    }
}

@Suite("LocalEmbedder")
struct LocalEmbedderTests {

    private func missingEmbedder() -> LocalEmbedder {
        LocalEmbedder(modelDirectory: URL(fileURLWithPath: "/nonexistent/embedder"), scheduler: InferenceScheduler())
    }

    @Test("reports unavailable when the model is not installed, and refuses to embed")
    func notInstalled() async {
        let e = missingEmbedder()
        #expect(await e.healthCheck() == .unavailable("Embedding model not installed"))
        await #expect(throws: LocalModelError.self) { _ = try await e.embed(["x"]) }
    }

    @Test("advertises only the embedding capability and cannot generate")
    func capabilities() async {
        let e = missingEmbedder()
        #expect(e.capabilities == [.embedding])
        #expect(e.isLocal)                                          // routed as local, not cloud
        var threw = false
        do { for try await _ in await e.generate(messages: [], tools: [], options: GenerationOptions()) {} } catch { threw = true }
        #expect(threw)
    }

    @Test("empty input returns immediately without loading a model")
    func emptyInput() async throws {
        #expect(try await missingEmbedder().embed([]).isEmpty)
    }

    @Test("model discovery does not register the Embedders folder as a chat model")
    func registrySkipsEmbedders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeBundle(_ path: String) throws {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"model_type\":\"qwen3\"}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data().write(to: dir.appendingPathComponent("model.safetensors"))
        }
        try makeBundle("Chat-Model")
        try makeBundle("Embedders/BAAI--bge-small-en-v1.5")
        let registry = ModelRegistry()
        try await registry.discover(localDirectory: root, credentials: CredentialStore())
        let ids = await registry.allProviders.map(\.id)
        #expect(ids == ["local:Chat-Model"])
    }
}
