import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@MainActor
@Suite("KnowledgeModel")
struct KnowledgeModelTests {
    func make() -> (KnowledgeModel, KnowledgeStore) {
        let settings = KnowledgeSettings(defaults: UserDefaults(suiteName: "km-\(UUID().uuidString)")!)
        let store = KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: KnowledgeStub.embedder())
        return (KnowledgeModel(store: store, settings: settings), store)
    }
    func brief() -> Brief {
        var b = Brief.new(title: "t", target: .make(modelFamily: "claude", surface: .claudeCode))
        b.setText("Add retry to uploads", for: .goal)
        return b
    }

    @Test("starts undecided with the card showing; turning on records and updates the chip count")
    func flow() async {
        let (m, _) = make()
        await m.refresh()
        #expect(m.prompt == .card)
        await m.noteAccepted(brief())
        #expect(m.learnedCount == 0)               // opted out: counted, not stored
        await m.turnOn()
        #expect(m.decision == .enabled && m.prompt == nil)
        await m.noteAccepted(brief())
        #expect(m.learnedCount == 1)
    }

    @Test("turning off keeps entries; wipeLearned removes history only")
    func offAndWipe() async throws {
        let (m, store) = make()
        await m.turnOn()
        await m.noteAccepted(brief())
        try await store.addAll([KnowledgeEntry(kind: .technique, pack: "p", text: "packed")])
        await m.turnOff()
        #expect(m.learnedCount == 1)
        await m.noteAccepted({ var b = brief(); b.setText("Another goal", for: .goal); return b }())
        #expect(m.learnedCount == 1)
        await m.wipeLearned()
        #expect(m.learnedCount == 0)
        #expect(m.entries.map(\.text) == ["packed"])
    }

    @Test("delete and disable act on one entry")
    func deleteDisable() async throws {
        let (m, store) = make()
        let a = KnowledgeEntry(kind: .technique, text: "a"), b = KnowledgeEntry(kind: .technique, text: "b")
        try await store.addAll([a, b])
        await m.delete(id: a.id)
        await m.setEnabled(false, id: b.id)
        #expect(m.entries.map(\.id) == [b.id])
        #expect(m.entries.first?.enabled == false)
    }
}
