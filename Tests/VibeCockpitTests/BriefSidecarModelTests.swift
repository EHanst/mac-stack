import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@MainActor
@Suite("BriefSidecarModel")
struct BriefSidecarModelTests {
    private func workbench(goal: String = "Add retry to uploads") async -> BriefWorkbenchModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
        let m = BriefWorkbenchModel(store: BriefStore(directory: dir), saveDelay: .zero)
        await m.newBrief(title: "t")
        m.setText(goal, for: .goal)
        return m
    }
    private func model(reply: @escaping @Sendable () async throws -> String) -> BriefSidecarModel {
        BriefSidecarModel(sidecar: BriefSidecar { _ in try await reply() })
    }
    private func settle(_ m: BriefSidecarModel) async {
        for _ in 0..<200 where m.phase != .idle {
            if case .failed = m.phase { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("interview shows questions and leaves the brief unchanged")
    func interview() async {
        let wb = await workbench()
        let before = wb.selected
        let m = model { "<questions>\n- goal: Which endpoint?\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        #expect(m.result?.questions.count == 1)
        #expect(m.briefID == wb.selectedID)
        #expect(wb.selected == before)
    }

    @Test("answering appends Q and A to that section")
    func answer() async {
        let wb = await workbench()
        let m = model { "<questions>\n- constraints: How many attempts?\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        m.answer(m.result!.questions[0], text: "3", in: wb)
        #expect(wb.selected?.text(of: .constraints) == "Q: How many attempts?\nA: 3")
        #expect(m.result?.questions.isEmpty == true)
    }

    @Test("accepting a finding appends its addition once")
    func acceptOnce() async {
        let wb = await workbench()
        let m = model { "<findings>\n- constraints | No limit | add: Retry at most 3 times.\n</findings>" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        let f = m.result!.findings[0]
        m.accept(f, in: wb)
        m.accept(f, in: wb)
        #expect(wb.selected?.text(of: .constraints) == "Retry at most 3 times.")
    }

    @Test("cancel returns to idle at once and the late reply is ignored")
    func cancel() async {
        let wb = await workbench()
        let gate = AsyncGate()
        let m = model { await gate.wait(); return "<questions>\n- goal: late\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        m.cancel()
        #expect(m.phase == .idle)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.result == nil)
    }

    @Test("a second run replaces the first; only the second result shows")
    func secondWins() async {
        let wb = await workbench(goal: "first goal")
        let gate = AsyncGate()
        let m = BriefSidecarModel(sidecar: BriefSidecar { messages in
            if messages.last?.content.contains("first goal") == true {
                await gate.wait(); return "<questions>\n- goal: first\n</questions>"
            }
            return "<questions>\n- goal: second\n</questions>"
        })
        m.run(.interview, brief: wb.selected!)
        wb.setText("second goal", for: .goal)
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.result?.questions.first?.text == "second")
    }

    @Test("an empty goal fails with one sentence and no result")
    func emptyGoal() async {
        let wb = await workbench(goal: "")
        let m = model { "unused" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        #expect(m.phase == .failed("Write a goal first."))
        #expect(m.result == nil)
    }

    @Test("a model error becomes a plain failure and keeps the brief")
    func modelError() async {
        struct Boom: LocalizedError { var errorDescription: String? { "No model is loaded." } }
        let wb = await workbench()
        let before = wb.selected
        let m = model { throw Boom() }
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        #expect(m.phase == .failed("No model is loaded."))
        #expect(wb.selected == before)
    }

    @Test("applying to a brief that was deleted does nothing")
    func staleApply() async {
        let wb = await workbench()
        let m = model { "<findings>\n- goal | vague | add: Be specific.\n</findings>" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        let f = m.result!.findings[0]
        await wb.deleteSelected()
        m.accept(f, in: wb)
        #expect(wb.briefs.isEmpty)
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}
