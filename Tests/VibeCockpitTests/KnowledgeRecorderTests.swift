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
    func brief(goal: String = "Add retry with backoff to uploads") -> Brief {
        var b = Brief.new(title: "t", target: .make(modelFamily: "claude", surface: .claudeCode))
        b.setText(goal, for: .goal)
        b.setText("Retry at most 3 times", for: .constraints)
        return b
    }

    @Test("nothing is stored while opted out, but the accept is counted")
    func optedOut() async throws {
        let (r, store, settings) = setup(recording: false)
        await r.recordAccepted(brief())
        #expect(try await store.all().isEmpty)
        #expect(settings.acceptedBriefCount == 1)
    }

    @Test("opted in: an exemplar with the sections, target and intent is stored")
    func stores() async throws {
        let (r, store, _) = setup(recording: true)
        await r.recordAccepted(brief())
        let e = try await store.all().first
        #expect(e?.kind == .exemplar)
        #expect(e?.target == "claude")
        #expect(e?.pack == nil)
        #expect(e?.text.contains("## goal") == true && e?.text.contains("Retry at most 3 times") == true)
        #expect(e?.meta["intent"] == "Add retry with backoff to uploads")
    }

    @Test("secrets are redacted before anything is stored")
    func redacts() async throws {
        let (r, store, _) = setup(recording: true)
        await r.recordAccepted(brief(goal: "Upload with key AKIAIOSFODNN7EXAMPLE"))
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

    @Test("disabled sections are left out; a brief without a goal records nothing")
    func sectionsAndGoal() async throws {
        let (r, store, _) = setup(recording: true)
        var b = brief()
        if let i = b.sections.firstIndex(where: { $0.kind == .constraints }) { b.sections[i].enabled = false }
        await r.recordAccepted(b)
        #expect(try await store.all().first?.text.contains("Retry at most 3 times") == false)
        await r.recordAccepted(Brief.new(title: "empty", target: .make(modelFamily: "claude", surface: .claudeCode)))
        #expect(try await store.all().count == 1)
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
        await r.recordAccepted(brief(goal: String(repeating: "goal ", count: 3000)))
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
        await r.recordAccepted(brief(goal: "A different goal entirely"))
        #expect(try await store.all().count == 1)
    }
}
