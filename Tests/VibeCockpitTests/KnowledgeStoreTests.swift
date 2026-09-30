import Testing
import Foundation
@testable import StackCore

@Suite("RankFusion")
struct RankFusionTests {
    @Test("an id in both lists outranks ids in one")
    func fusesLists() {
        let out = RankFusion.fuse([["a", "b", "c"], ["c", "d"]])
        #expect(out.first?.id == "c")
        #expect(Set(out.map(\.id)) == ["a", "b", "c", "d"])
    }

    @Test("ties break by id so the order is deterministic")
    func deterministic() {
        let out = RankFusion.fuse([["b"], ["a"]])
        #expect(out.map(\.id) == ["a", "b"])
    }

    @Test("empty input gives empty output")
    func empty() {
        #expect(RankFusion.fuse([]).isEmpty)
        #expect(RankFusion.fuse([[], []]).isEmpty)
    }
}

@Suite("KnowledgeStore")
struct KnowledgeStoreTests {
    func makeStore(_ embedder: KnowledgeEmbedder? = KnowledgeStub.embedder(),
                   url: URL = KnowledgeStub.tempURL()) -> KnowledgeStore {
        KnowledgeStore(dbURL: url, dimension: KnowledgeStub.dim, embedder: embedder)
    }
    func note(_ text: String, target: String? = nil, pack: String? = nil,
              kind: KnowledgeKind = .technique) -> KnowledgeEntry {
        KnowledgeEntry(kind: kind, target: target, pack: pack, text: text)
    }

    @Test("adds entries and lists them newest first")
    func addAndList() async throws {
        let s = makeStore()
        let added = try await s.addAll([note("first"), note("second")])
        #expect(added == 2)
        let all = try await s.all()
        #expect(all.count == 2)
        #expect(try await s.counts()[.technique] == 2)
        #expect(try await s.embeddedCount() == 2)
    }

    @Test("identical entries are stored once")
    func dedupes() async throws {
        let s = makeStore()
        #expect(try await s.addAll([note("same text")]) == 1)
        #expect(try await s.addAll([note("same text")]) == 0)
        #expect(try await s.all().count == 1)
    }

    @Test("the same text under a different pack is a different entry")
    func packScopedHash() async throws {
        let s = makeStore()
        #expect(try await s.addAll([note("x", pack: "a"), note("x", pack: "b")]) == 2)
    }

    @Test("text over the cap is truncated")
    func truncates() async throws {
        let s = makeStore()
        try await s.addAll([note(String(repeating: "a", count: KnowledgeLimits.maxTextChars + 500))])
        #expect(try await s.all().first?.text.count == KnowledgeLimits.maxTextChars)
    }

    @Test("meta, target and kind round-trip")
    func roundTrip() async throws {
        let s = makeStore()
        var e = note("round trip", target: "claude", kind: .exemplar)
        e.meta = ["intent": "add retry"]
        try await s.addAll([e])
        let back = try await s.entry(id: e.id)
        #expect(back?.meta == ["intent": "add retry"])
        #expect(back?.target == "claude")
        #expect(back?.kind == .exemplar)
    }

    @Test("delete removes the entry and its vector row")
    func deletes() async throws {
        let s = makeStore()
        let e = note("delete me")
        try await s.addAll([e, note("keep me")])
        try await s.delete(ids: [e.id])
        #expect(try await s.entry(id: e.id) == nil)
        #expect(try await s.embeddedCount() == 1)
    }

    @Test("wipeHistory keeps pack entries, wipeAll removes everything")
    func wipes() async throws {
        let s = makeStore()
        try await s.addAll([note("mine", kind: .exemplar), note("packed", pack: "p")])
        try await s.wipeHistory()
        #expect(try await s.all().map(\.text) == ["packed"])
        try await s.wipeAll()
        #expect(try await s.all().isEmpty)
        #expect(try await s.embeddedCount() == 0)
    }

    @Test("an unreadable file is rebuilt and didReset is set")
    func recoversFromGarbage() async throws {
        let url = KnowledgeStub.tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a sqlite database, just text".utf8).write(to: url)
        let s = makeStore(url: url)
        try await s.open()
        #expect(await s.didReset)
        #expect(try await s.addAll([note("works again")]) == 1)
    }

    @Test("entries survive reopening the same file")
    func persists() async throws {
        let url = KnowledgeStub.tempURL()
        let a = makeStore(url: url)
        try await a.addAll([note("lasting")])
        await a.close()
        let b = makeStore(url: url)
        #expect(try await b.all().map(\.text) == ["lasting"])
        #expect(await b.didReset == false)
    }
}

@Suite("KnowledgeSignals")
struct KnowledgeSignalTests {
    func makeStore() -> KnowledgeStore {
        KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: KnowledgeStub.embedder())
    }

    @Test("accepted raises weight, rejected lowers it")
    func adjusts() async throws {
        let s = makeStore()
        let e = KnowledgeEntry(kind: .technique, text: "note")
        try await s.addAll([e])
        try await s.applySignal(ids: [e.id], outcome: .accepted)
        #expect(abs(try await s.entry(id: e.id)!.weight - 1.15) < 0.0001)
        try await s.applySignal(ids: [e.id], outcome: .rejected)
        #expect(abs(try await s.entry(id: e.id)!.weight - 0.92) < 0.0001)
        try await s.applySignal(ids: [e.id], outcome: .edited)
        #expect(abs(try await s.entry(id: e.id)!.weight - 0.92) < 0.0001)
    }

    @Test("weight is clamped to the allowed range")
    func clamps() async throws {
        let s = makeStore()
        let e = KnowledgeEntry(kind: .technique, text: "clamp me")
        try await s.addAll([e])
        for _ in 0..<40 { try await s.applySignal(ids: [e.id], outcome: .rejected) }
        #expect(try await s.entry(id: e.id)!.weight == KnowledgeLimits.weightRange.lowerBound)
        for _ in 0..<80 { try await s.applySignal(ids: [e.id], outcome: .accepted) }
        #expect(try await s.entry(id: e.id)!.weight == KnowledgeLimits.weightRange.upperBound)
    }

    @Test("a signal for an unknown id is ignored")
    func unknownID() async throws {
        let s = makeStore()
        try await s.applySignal(ids: ["nope"], outcome: .accepted)
    }
}

@Suite("KnowledgePacksInStore")
struct KnowledgePackStoreTests {
    func makeStore() -> KnowledgeStore {
        KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: KnowledgeStub.embedder())
    }
    let info = KnowledgePackInfo(id: "p1", name: "Pack One", version: 1, license: "MIT", attribution: "Someone")

    @Test("summaries count a pack's entries and show enabled state")
    func summaries() async throws {
        let s = makeStore()
        try await s.registerPack(info)
        try await s.addAll([KnowledgeEntry(kind: .technique, pack: "p1", text: "a"),
                            KnowledgeEntry(kind: .technique, pack: "p1", text: "b")])
        var sum = try await s.packSummaries()
        #expect(sum == [KnowledgePackSummary(info: info, count: 2, enabled: true)])
        try await s.setPackEnabled(false, pack: "p1")
        sum = try await s.packSummaries()
        #expect(sum.first?.enabled == false)
    }

    @Test("removing a pack deletes its entries and its row")
    func removes() async throws {
        let s = makeStore()
        try await s.registerPack(info)
        try await s.addAll([KnowledgeEntry(kind: .technique, pack: "p1", text: "a"),
                            KnowledgeEntry(kind: .exemplar, text: "mine")])
        #expect(try await s.removePack("p1") == 1)
        #expect(try await s.all().map(\.text) == ["mine"])
        #expect(try await s.packSummaries().isEmpty)
    }
}
