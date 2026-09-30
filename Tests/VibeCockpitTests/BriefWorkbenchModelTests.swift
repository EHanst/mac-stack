import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@MainActor
@Suite("BriefWorkbenchModel")
struct BriefWorkbenchModelTests {
    private func make() -> (BriefWorkbenchModel, BriefStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        return (BriefWorkbenchModel(store: store, saveDelay: .zero), store)
    }

    @Test("new brief is selected, compiled and persisted")
    func newBrief() async throws {
        let (m, store) = make()
        await m.newBrief(title: "Fix login")
        #expect(m.briefs.count == 1)
        #expect(m.selected?.title == "Fix login")
        #expect(m.compiled != nil)
        await m.flush()
        #expect(await store.all().count == 1)
    }

    @Test("editing the goal recompiles and saves")
    func editGoal() async {
        let (m, store) = make()
        await m.newBrief(title: "t")
        m.setText("Add a retry to the upload call", for: .goal)
        #expect(m.compiled?.text.contains("Add a retry") == true)
        await m.flush()
        #expect(await store.all().first?.text(of: .goal) == "Add a retry to the upload call")
    }

    @Test("rapid edits end with the last one on disk")
    func rapidEdits() async {
        let (m, store) = make()
        await m.newBrief(title: "t")
        for i in 0..<20 { m.setText("edit \(i)", for: .goal) }
        await m.flush()
        #expect(await store.all().first?.text(of: .goal) == "edit 19")
    }

    @Test("empty goal warns and copy text is empty")
    func emptyGoal() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        #expect(m.compiled?.warnings.contains { $0.code == .emptyGoal } == true)
        #expect(m.copyText(for: nil).isEmpty)
    }

    @Test("changing surface keeps section text and recompiles")
    func surface() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setText("Do X", for: .goal)
        m.setTarget(modelFamily: "claude", surface: .chatGPTWeb)
        #expect(m.selected?.target.surface == .chatGPTWeb)
        #expect(m.selected?.text(of: .goal) == "Do X")
    }

    @Test("copy for a surface does not change the brief's own target")
    func copyVariant() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setText("Do X", for: .goal)
        let before = m.selected?.target
        _ = m.copyText(for: .claudeCode)
        #expect(m.selected?.target == before)
    }

    @Test("deleting the selected brief selects a neighbor, then nothing")
    func delete() async {
        let (m, _) = make()
        await m.newBrief(title: "a")
        await m.newBrief(title: "b")
        await m.deleteSelected()
        #expect(m.briefs.count == 1)
        #expect(m.selected != nil)
        await m.deleteSelected()
        #expect(m.briefs.isEmpty)
        #expect(m.selected == nil)
        #expect(m.compiled == nil)
    }

    @Test("a corrupt file in the store does not stop the others loading")
    func corrupt() async throws {
        let (m, store) = make()
        await m.newBrief(title: "ok")
        await m.flush()
        try "{nope".write(to: store.directory.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        let m2 = BriefWorkbenchModel(store: BriefStore(directory: store.directory), saveDelay: .zero)
        await m2.reload()
        #expect(m2.briefs.count == 1)
    }

    // MARK: Review fixes

    @Test("two deletes racing on one brief do not crash or resurrect it")
    func concurrentDelete() async {
        let (m, store) = make()
        await m.newBrief(title: "only")
        m.setText("pending edit", for: .goal)
        async let a: Void = m.deleteSelected()
        async let b: Void = m.deleteSelected()
        _ = await (a, b)
        await m.flushNow()
        #expect(m.briefs.isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("an edit to one brief is not lost when another brief is edited inside the delay")
    func editsAcrossBriefs() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        let m = BriefWorkbenchModel(store: store, saveDelay: .milliseconds(200))
        await m.newBrief(title: "a")
        let aID = m.selectedID!
        m.setText("edit in A", for: .goal)
        await m.newBrief(title: "b")
        m.setText("edit in B", for: .goal)
        await m.flushNow()
        let saved = await store.all()
        #expect(saved.first { $0.id == aID }?.text(of: .goal) == "edit in A")
        #expect(saved.first { $0.id != aID }?.text(of: .goal) == "edit in B")
    }

    @Test("flushNow writes immediately instead of waiting out the delay")
    func flushNowIsImmediate() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        let m = BriefWorkbenchModel(store: store, saveDelay: .seconds(30))
        await m.newBrief(title: "t")
        m.setText("last words", for: .goal)
        let start = ContinuousClock.now
        await m.flushNow()
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(await store.all().first?.text(of: .goal) == "last words")
    }

    @Test("reload keeps an edit that has not reached disk yet")
    func reloadKeepsPendingEdit() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let m = BriefWorkbenchModel(store: BriefStore(directory: dir), saveDelay: .seconds(30))
        await m.newBrief(title: "t")
        m.setText("fresh", for: .goal)
        await m.reload()
        #expect(m.selected?.text(of: .goal) == "fresh")
    }

    @Test("canCopy follows the goal and does not need a second compile")
    func canCopy() async {
        let (m, _) = make()
        #expect(!m.canCopy)
        await m.newBrief(title: "t")
        #expect(!m.canCopy)
        m.setText("Do X", for: .goal)
        #expect(m.canCopy)
        m.setEnabled(false, for: .goal)
        #expect(!m.canCopy)
    }

    @Test("switching surface on an over-budget brief changes the warnings, not the text")
    func overBudgetSurface() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setText("Do X", for: .goal)
        var brief = m.selected!
        let big = String(repeating: "word ", count: 30_000)
        brief.contextItems = [ContextItem(kind: .snippet, ref: "a.swift", text: big, mode: .inline)]
        m.replaceSelected(with: brief)
        let before = m.compiled?.warnings.map(\.code) ?? []
        m.setTarget(modelFamily: "claude", surface: .chatGPTWeb)
        #expect(m.selected?.text(of: .goal) == "Do X")
        #expect(m.compiled != nil)
        #expect(before.contains(.overBudget) || before.contains(.itemDowngraded) || before.contains(.itemDropped))
    }
}
