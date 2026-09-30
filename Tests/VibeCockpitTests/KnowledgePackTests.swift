import Testing
import Foundation
@testable import StackCore

@Suite("KnowledgePackLoader")
struct KnowledgePackTests {
    func makeStore() -> KnowledgeStore {
        KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: KnowledgeStub.embedder())
    }
    func writePack(_ manifest: String, jsonl: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        if let jsonl { try Data(jsonl.utf8).write(to: dir.appendingPathComponent("entries.jsonl")) }
        return dir
    }
    let header = #""id":"fixture","name":"Fixture","version":1,"license":"CC0","attribution":"nobody""#

    @Test("loads inline entries and registers the pack")
    func inline() async throws {
        let dir = try writePack(#"{\#(header),"entries":[{"kind":"technique","text":"Be explicit about output format"},{"kind":"targetNote","target":"claude","text":"Claude follows XML tags well"}]}"#)
        let s = makeStore()
        #expect(try await KnowledgePackLoader.load(directory: dir, into: s) == 2)
        #expect(try await s.packSummaries().first?.count == 2)
        #expect(try await s.all().allSatisfy { $0.pack == "fixture" })
    }

    @Test("loads entries from a JSONL file, skipping blank lines and empty text")
    func jsonl() async throws {
        let dir = try writePack(#"{\#(header),"entriesFile":"entries.jsonl"}"#,
                                jsonl: "{\"kind\":\"constraint\",\"text\":\"Answer in at most 3 sentences\"}\n\n{\"kind\":\"constraint\",\"text\":\"  \"}\n")
        let s = makeStore()
        #expect(try await KnowledgePackLoader.load(directory: dir, into: s) == 1)
    }

    @Test("loading twice adds nothing; a changed pack replaces removed entries")
    func idempotentAndUpdates() async throws {
        let v1 = try writePack(#"{\#(header),"entries":[{"kind":"technique","text":"one"},{"kind":"technique","text":"two"}]}"#)
        let s = makeStore()
        _ = try await KnowledgePackLoader.load(directory: v1, into: s)
        #expect(try await KnowledgePackLoader.load(directory: v1, into: s) == 0)
        let v2 = try writePack(#"{\#(header),"entries":[{"kind":"technique","text":"two"},{"kind":"technique","text":"three"}]}"#)
        #expect(try await KnowledgePackLoader.load(directory: v2, into: s) == 1)
        #expect(Set(try await s.all().map(\.text)) == ["two", "three"])
    }

    @Test("a disabled entry stays disabled when the pack is reloaded")
    func keepsDisabled() async throws {
        let dir = try writePack(#"{\#(header),"entries":[{"kind":"technique","text":"keep off"}]}"#)
        let s = makeStore()
        _ = try await KnowledgePackLoader.load(directory: dir, into: s)
        let id = try await s.all().first!.id
        try await s.setEnabled(false, id: id)
        _ = try await KnowledgePackLoader.load(directory: dir, into: s)
        #expect(try await s.entry(id: id)?.enabled == false)
    }

    @Test("bad manifests are rejected with a pack error")
    func rejects() async throws {
        let s = makeStore()
        let noFile = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        await #expect(throws: KnowledgeError.self) { try await KnowledgePackLoader.load(directory: noFile, into: s) }
        let badID = try writePack(#"{"id":"../evil","name":"x","version":1,"license":"x","attribution":"x","entries":[]}"#)
        await #expect(throws: KnowledgeError.self) { try await KnowledgePackLoader.load(directory: badID, into: s) }
        let notJSON = try writePack("not json")
        await #expect(throws: KnowledgeError.self) { try await KnowledgePackLoader.load(directory: notJSON, into: s) }
    }
}
