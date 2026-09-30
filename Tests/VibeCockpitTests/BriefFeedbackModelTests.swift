import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@MainActor
@Suite("BriefFeedbackModel")
struct BriefFeedbackModelTests {
    private func workbench(input: String = "Add retry to uploads") async -> BriefWorkbenchModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        let m = BriefWorkbenchModel(store: BriefStore(directory: dir), saveDelay: .zero)
        await m.newBrief(title: "t", input: input)
        return m
    }
    private func model(_ wb: BriefWorkbenchModel, reply: @escaping @Sendable () async throws -> String) -> BriefFeedbackModel {
        BriefFeedbackModel(sidecar: BriefSidecar { _ in try await reply() }, workbench: wb)
    }
    private func settle(_ m: BriefFeedbackModel) async {
        for _ in 0..<200 where m.phase == .editing { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("an instruction rewrites the body directly and Undo restores the linked state")
    func editAndUndo() async {
        let wb = await workbench()
        let id = wb.selectedID!
        let m = model(wb) { "<revision>\nAdd retry to uploads, at most 3 attempts.\n</revision>" }
        m.send("limit it to 3 attempts", brief: wb.selected!)
        await settle(m)
        #expect(wb.selected?.body == "Add retry to uploads, at most 3 attempts.")
        #expect(m.canUndo(briefID: id))
        m.undo(briefID: id)
        #expect(wb.selected?.body == nil)
        #expect(wb.selected?.effectiveBody == "Add retry to uploads")
        #expect(!m.canUndo(briefID: id))
    }

    @Test("Undo steps back through successive edits")
    func undoStack() async {
        let wb = await workbench()
        let id = wb.selectedID!
        let replies = LockedReplies(["<revision>\nv1 text\n</revision>", "<revision>\nv2 text\n</revision>"])
        let m = model(wb) { replies.next() }
        m.send("one", brief: wb.selected!); await settle(m)
        m.send("two", brief: wb.selected!); await settle(m)
        #expect(wb.selected?.body == "v2 text")
        m.undo(briefID: id)
        #expect(wb.selected?.body == "v1 text")
        m.undo(briefID: id)
        #expect(wb.selected?.body == nil)
    }

    @Test("an edit that drops a quoted or coded literal is refused and the brief is untouched")
    func droppedLiteral() async {
        let wb = await workbench(input: "Rename `oldName` in Foo.swift")
        let m = model(wb) { "<revision>\nRename the function\n</revision>" }
        m.send("tidy", brief: wb.selected!)
        await settle(m)
        if case .failed = m.phase {} else { Issue.record("expected failure, got \(m.phase)") }
        #expect(wb.selected?.body == nil)
        #expect(!m.canUndo(briefID: wb.selectedID!))
    }

    @Test("a reply with no revision tag changes nothing")
    func noRevision() async {
        let wb = await workbench()
        let m = model(wb) { "Sure, done!" }
        m.send("x", brief: wb.selected!)
        await settle(m)
        if case .failed = m.phase {} else { Issue.record("expected failure") }
        #expect(wb.selected?.body == nil)
    }

    @Test("brainstorm keeps at most 2 questions and 2 tips, and skips an unchanged brief unless forced")
    func brainstorm() async {
        let wb = await workbench()
        let calls = Counter()
        let m = model(wb) {
            calls.bump()
            return "<questions>\n- a?\n- b?\n- c?\n</questions>\n<tips>\n- t1\n- t2\n- t3\n</tips>"
        }
        m.refreshBrainstorm(brief: wb.selected!)
        for _ in 0..<200 where m.brainstormPhase == .running { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(m.questions.count == 2 && m.tips.count == 2)
        m.refreshBrainstorm(brief: wb.selected!)
        #expect(calls.value == 1)
        #expect(m.brainstormPhase == .idle)
        m.refreshBrainstorm(brief: wb.selected!, force: true)
        for _ in 0..<200 where m.brainstormPhase == .running { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.value == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class LockedReplies: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String]
    init(_ items: [String]) { self.items = items }
    func next() -> String { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? "" : items.removeFirst() }
}
