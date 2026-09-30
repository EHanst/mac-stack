import Testing
import Foundation
@testable import StackCore

@Suite("KnowledgeRecorder")
struct KnowledgeRecorderTests {
    func setup(recording: Bool) -> (KnowledgeRecorder, KnowledgeStore, KnowledgeSettings) {
        let settings = KnowledgeSettings(defaults: UserDefaults(suiteName: "kr-\(UUID().uuidString)")!)
        if recording { settings.setDecision(.enabled) }
        let store = KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: KnowledgeStub.embedder())
        return (KnowledgeRecorder(store: store, settings: settings), store, settings)
    }
    func brief(input: String = "Add retry with backoff to uploads") -> Brief {
        Brief.new(title: "t", input: input, target: .make(modelFamily: "claude", surface: .claudeCode))
    }

    @Test("nothing is stored while opted out, but the accept is counted")
    func optedOut() async throws {
        let (r, store, settings) = setup(recording: false)
        await r.recordAccepted(brief())
        #expect(try await store.all().isEmpty)
        #expect(settings.acceptedBriefCount == 1)
    }

    @Test("opted in: an exemplar with the brief's text, target and intent is stored")
    func exemplar() {
        let b = Brief.new(title: "t", input: "Add retry\nwith backoff", target: .make(modelFamily: "claude", surface: .claudeCode))
        let e = KnowledgeRecorder.exemplar(from: b, now: Date())
        #expect(e?.text == "Add retry\nwith backoff")
        #expect(e?.meta["intent"] == "Add retry with backoff")
        #expect(e?.target == "claude")
    }

    @Test("secrets are redacted before anything is stored")
    func redacts() async throws {
        let (r, store, _) = setup(recording: true)
        await r.recordAccepted(brief(input: "Upload with key AKIAIOSFODNN7EXAMPLE"))
        let stored = try await store.all()
        #expect(stored.count == 1)
        #expect(!stored[0].text.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!(stored[0].meta["intent"] ?? "").contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test("context item contents are never stored")
    func skipsContextItems() async throws {
        let (r, store, _) = setup(recording: true)
        var b = brief()
        b.contextItems = [ContextItem(kind: .file, ref: "Secrets.swift", text: "let unique_marker_9f3 = 1", mode: .inline)]
        await r.recordAccepted(b)
        let text = try await store.all().first?.text ?? ""
        #expect(!text.contains("unique_marker_9f3") && !text.contains("Secrets.swift"))
    }

    @Test("an empty brief records nothing; an edited brief records its body")
    func exemplarEdges() {
        var b = Brief.new(title: "t", input: " ", target: .make(modelFamily: "claude", surface: .claudeCode))
        #expect(KnowledgeRecorder.exemplar(from: b, now: Date()) == nil)
        b.body = "Edited text"
        #expect(KnowledgeRecorder.exemplar(from: b, now: Date())?.text == "Edited text")
    }

    @Test("accepting the same content twice stores it once")
    func dedupes() async throws {
        let (r, store, _) = setup(recording: true)
        let b = brief()
        await r.recordAccepted(b); await r.recordAccepted(b)
        #expect(try await store.all().count == 1)
    }

    @Test("very long text is truncated to the store limit")
    func truncates() async throws {
        let (r, store, _) = setup(recording: true)
        await r.recordAccepted(brief(input: String(repeating: "goal ", count: 3000)))
        #expect(try await store.all().first!.text.count <= KnowledgeLimits.maxTextChars)
    }

    @Test("signals change weights only while opted in")
    func signals() async throws {
        let (on, store, _) = setup(recording: true)
        let e = KnowledgeEntry(kind: .technique, text: "note")
        try await store.addAll([e])
        await on.recordSignal(ids: [e.id], outcome: .accepted)
        #expect(try await store.entry(id: e.id)!.weight > 1.1)

        let (off, store2, _) = setup(recording: false)
        try await store2.addAll([e])
        await off.recordSignal(ids: [e.id], outcome: .accepted)
        #expect(try await store2.entry(id: e.id)!.weight == 1)
    }

    @Test("opting out stops recording at once and keeps what is there")
    func optOut() async throws {
        let (r, store, settings) = setup(recording: true)
        await r.recordAccepted(brief())
        settings.setDecision(.declined)
        await r.recordAccepted(brief(input: "A different goal entirely"))
        #expect(try await store.all().count == 1)
    }
}
