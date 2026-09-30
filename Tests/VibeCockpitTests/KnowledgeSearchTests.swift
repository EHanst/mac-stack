import Testing
import Foundation
@testable import StackCore

@Suite("KnowledgeSearch")
struct KnowledgeSearchTests {
    func makeStore(_ e: KnowledgeEmbedder? = KnowledgeStub.embedder()) -> KnowledgeStore {
        KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: e)
    }
    func note(_ text: String, target: String? = nil) -> KnowledgeEntry { KnowledgeEntry(kind: .technique, target: target, text: text) }

    @Test("the most relevant entry comes first")
    func ranks() async throws {
        let s = makeStore()
        try await s.addAll([note("State the output format as a JSON schema"),
                            note("Keep function names in snake_case for python"),
                            note("Ask for tests alongside the change")])
        let hits = await s.search(query: "what json output format to use", target: nil)
        #expect(hits.first?.entry.text.contains("JSON schema") == true)
    }

    @Test("target filter keeps generic entries and matching targets only")
    func targetFilter() async throws {
        let s = makeStore()
        try await s.addAll([note("generic retry advice"), note("claude retry advice", target: "claude"),
                            note("gpt retry advice", target: "gpt")])
        let texts = await s.search(query: "retry advice", target: "claude").map(\.entry.text)
        #expect(Set(texts) == ["generic retry advice", "claude retry advice"])
        let none = await s.search(query: "retry advice", target: nil).map(\.entry.text)
        #expect(none == ["generic retry advice"])
    }

    @Test("disabled entries are not returned")
    func disabled() async throws {
        let s = makeStore()
        let e = note("secret sauce about retries")
        try await s.addAll([e])
        try await s.setEnabled(false, id: e.id)
        #expect(await s.search(query: "retries", target: nil).isEmpty)
    }

    @Test("deleted entries stop matching")
    func deletedGone() async throws {
        let s = makeStore()
        let e = note("remove this retries note")
        try await s.addAll([e])
        try await s.delete(ids: [e.id])
        #expect(await s.search(query: "retries", target: nil).isEmpty)
    }

    @Test("without an embedder, text search still works")
    func noEmbedder() async throws {
        let s = makeStore(nil)
        try await s.addAll([note("pagination cursor advice")])
        #expect(await s.search(query: "pagination", target: nil).count == 1)
    }

    @Test("when the embedder fails on add, the entry is kept and re-embedded later")
    func embedderFailsThenRecovers() async throws {
        let (embedder, sw) = KnowledgeStub.flaky()
        let s = makeStore(embedder)
        try await s.addAll([note("rate limit advice")])
        #expect(try await s.embeddedCount() == 0)
        #expect(await s.search(query: "rate limit", target: nil).count == 1)   // text search only
        sw.failing = false
        #expect(await s.reembedMissing() == 1)
        #expect(try await s.embeddedCount() == 1)
    }

    @Test("a dimension change keeps entries and lets them be re-embedded")
    func dimensionChange() async throws {
        let url = KnowledgeStub.tempURL()
        let a = KnowledgeStore(dbURL: url, dimension: 32, embedder: KnowledgeStub.embedder(dim: 32))
        try await a.addAll([note("some lasting advice")])
        await a.close()
        let b = KnowledgeStore(dbURL: url, dimension: 16, embedder: KnowledgeStub.embedder(dim: 16))
        try await b.open()
        #expect(try await b.all().count == 1)
        #expect(try await b.embeddedCount() == 0)
        #expect(await b.reembedMissing() == 1)
        #expect(await b.search(query: "lasting advice", target: nil).count == 1)
    }

    @Test("an empty or symbol-only query returns nothing without failing")
    func emptyQuery() async throws {
        let s = makeStore()
        try await s.addAll([note("anything")])
        _ = await s.search(query: "", target: nil)
        _ = await s.search(query: "   ", target: nil)
        _ = await s.search(query: "\"'(*)", target: nil)
    }
}
