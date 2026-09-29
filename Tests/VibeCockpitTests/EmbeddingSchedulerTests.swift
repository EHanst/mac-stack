import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

private actor StubEmbeddingProvider: ModelProvider {
    nonisolated let id: ProviderID = "stub-embed"
    nonisolated let capabilities: ProviderCapabilities = [.embedding]
    private(set) var embedCallCount = 0

    func generate(messages: [Message], tools: [ToolDefinition],
                  options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LocalModelError.unsupportedOperation("generate"))
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        return texts.map { _ in [Float](repeating: 0, count: 384) }
    }

    func healthCheck() async -> ProviderHealth { .healthy }
}

@Suite("EmbeddingScheduler")
struct EmbeddingSchedulerTests {

    private func makeStore(root: URL) async throws -> VectorStore {
        let store = VectorStore(dbURL: root.appendingPathComponent("test.sqlite"))
        try await store.open()
        return store
    }

    @Test("schedules 40 chunks and calls embed in two batches of 32/8")
    func batchesCorrectly() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("embed_sched_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try await makeStore(root: tmp)
        let provider = StubEmbeddingProvider()
        let scheduler = EmbeddingScheduler(provider: provider, store: store)
        let chunks = (0..<40).map { i in
            CodeChunk(filePath: "/ws/f.swift", declarationKind: "func",
                      startLine: i * 2 + 1, endLine: i * 2 + 2,
                      content: "func foo\(i)() {}")
        }
        await scheduler.schedule(chunks)
        try await scheduler.drain()
        let callCount = await provider.embedCallCount
        // 40 chunks, batchSize 32 → 2 embed calls (32 + 8)
        #expect(callCount == 2)
    }
}
