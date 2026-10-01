import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore

@MainActor
@Suite("BriefSidecarModel")
struct BriefSidecarModelTests {
    private func workbench(input: String = "Add retry to uploads") async -> BriefWorkbenchModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
        let m = BriefWorkbenchModel(store: BriefStore(directory: dir), saveDelay: .zero)
        await m.newBrief(title: "t", input: input)
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
        let m = model { "<questions>\n- Which endpoint?\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        #expect(m.result?.questions.count == 1)
        #expect(m.briefID == wb.selectedID)
        #expect(wb.selected == before)
    }

    @Test("answering appends Q and A to the input while linked")
    func answer() async {
        let wb = await workbench()
        let m = model { "<questions>\n- How many attempts?\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        m.answer(m.result!.questions[0], text: "3", in: wb)
        #expect(wb.selected?.input == "Add retry to uploads\n\nQ: How many attempts?\nA: 3")
        #expect(m.result?.questions.isEmpty == true)
    }

    @Test("accepting a finding appends its addition once")
    func acceptOnce() async {
        let wb = await workbench()
        let m = model { "<findings>\n- No limit | add: Retry at most 3 times.\n</findings>" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        let f = m.result!.findings[0]
        m.accept(f, in: wb)
        m.accept(f, in: wb)
        #expect(wb.selected?.input == "Add retry to uploads\n\nRetry at most 3 times.")
    }

    @Test("cancel returns to idle at once and the late reply is ignored")
    func cancel() async {
        let wb = await workbench()
        let gate = AsyncGate()
        let m = model { await gate.wait(); return "<questions>\n- late\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        m.cancel()
        #expect(m.phase == .idle)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.result == nil)
    }

    @Test("a second run replaces the first; only the second result shows")
    func secondWins() async {
        let wb = await workbench(input: "first goal")
        let gate = AsyncGate()
        let m = BriefSidecarModel(sidecar: BriefSidecar { messages in
            if messages.last?.content.contains("first goal") == true {
                await gate.wait(); return "<questions>\n- first\n</questions>"
            }
            return "<questions>\n- second\n</questions>"
        })
        m.run(.interview, brief: wb.selected!)
        wb.setInput("second goal")
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.result?.questions.first?.text == "second")
    }

    @Test("an empty input fails with one sentence and no result")
    func emptyInput() async {
        let wb = await workbench(input: "")
        let m = model { "unused" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        #expect(m.phase == .failed("Write something first."))
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
        let m = model { "<findings>\n- vague | add: Be specific.\n</findings>" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        let f = m.result!.findings[0]
        await wb.deleteSelected()
        m.accept(f, in: wb)
        #expect(wb.briefs.isEmpty)
    }

    @Test("a reply produces revision cards and leaves the brief unchanged")
    func reviseProposes() async {
        let wb = await workbench()
        let before = wb.selected
        let m = model { "<revision>Add retry with backoff</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "It timed out")
        await settle(m)
        #expect(m.result?.revisions.count == 1)
        #expect(wb.selected == before)
    }

    @Test("accepting applies once and saves the old text as a version")
    func acceptRevision() async {
        let wb = await workbench()
        let m = model { "<revision>Add retry with backoff</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await settle(m)
        let r = m.result!.revisions[0]
        m.acceptRevision(r, in: wb); m.acceptRevision(r, in: wb)
        #expect(wb.selected?.input == "Add retry with backoff")
        #expect(wb.selected?.versions.count == 1)
        #expect(wb.selected?.versions[0].input == "Add retry to uploads")
    }

    @Test("a stale card is refused when the brief was edited meanwhile")
    func staleRevision() async {
        let wb = await workbench()
        let m = model { "<revision>Something new</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await settle(m)
        wb.setInput("I changed this")
        m.acceptRevision(m.result!.revisions[0], in: wb)
        #expect(wb.selected?.input == "I changed this")
        #expect(m.result?.note == "The brief changed since the suggestion. Run it again.")
    }

    @Test("on an edited brief, accepting a revision writes body and leaves input alone")
    func acceptRevisionOnEdited() async {
        let wb = await workbench()
        wb.setBody("Edited text")
        let m = model { "<revision>Edited text, better</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await settle(m)
        m.acceptRevision(m.result!.revisions[0], in: wb)
        #expect(wb.selected?.body == "Edited text, better")
        #expect(wb.selected?.input == "Add retry to uploads")
    }

    @Test("on an edited brief, accepting a finding writes body and leaves input alone")
    func acceptFindingOnEdited() async {
        let wb = await workbench()
        wb.setBody("Edited text")
        let m = model { "<findings>\n- No limit | add: Retry at most 3 times.\n</findings>" }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        m.accept(m.result!.findings[0], in: wb)
        #expect(wb.selected?.body == "Edited text\n\nRetry at most 3 times.")
        #expect(wb.selected?.input == "Add retry to uploads")
    }

    @Test("a revision made while linked is refused once the brief is edited with different text")
    func staleLinkedThenEdited() async {
        let wb = await workbench()
        let m = model { "<revision>Something new</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await settle(m)
        wb.setBody("Hand edited")
        m.acceptRevision(m.result!.revisions[0], in: wb)
        #expect(wb.selected?.body == "Hand edited")
        #expect(wb.selected?.input == "Add retry to uploads")
        #expect(m.result?.note == "The brief changed since the suggestion. Run it again.")
    }

    @Test("a revision made while edited is refused once the brief is relinked to its input")
    func staleEditedThenRebuilt() async {
        let wb = await workbench()
        wb.setBody("Hand edited")
        let m = model { "<revision>Something new</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await settle(m)
        wb.restoreBody(nil, briefID: wb.selected!.id)
        m.acceptRevision(m.result!.revisions[0], in: wb)
        #expect(wb.selected?.body == nil)
        #expect(wb.selected?.input == "Add retry to uploads")
        #expect(m.result?.note == "The brief changed since the suggestion. Run it again.")
    }

    @Test("accepting after switching briefs edits the original brief only")
    func acceptOnOriginalBrief() async {
        let wb = await workbench()
        let firstID = wb.selectedID!
        let m = model { "<revision>Better goal</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await settle(m)
        await wb.newBrief(title: "other")
        m.acceptRevision(m.result!.revisions[0], in: wb)
        #expect(wb.briefs.first { $0.id == firstID }?.input == "Better goal")
        #expect(wb.selected?.input == "")
    }

    @Test("an empty reply fails with one sentence")
    func emptyReplyFails() async {
        let wb = await workbench()
        let m = model { "unused" }
        m.run(.revise, brief: wb.selected!, reply: "")
        await settle(m)
        #expect(m.phase == .failed("Paste the answer first."))
    }

    private func settleContinuation(_ m: BriefSidecarModel) async {
        for _ in 0..<200 where m.continuationPhase != .idle {
            if case .failed = m.continuationPhase { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a session becomes a new brief only after the model answers")
    func continuationCreatesBrief() async {
        let wb = await workbench()
        let summary = String(repeating: "The user first asked for upload retries and they were added. ", count: 3)
        let m = model { summary }
        m.continueFromSession("Add retry\nEdited Sources/Upload.swift", in: wb)
        await settleContinuation(m)
        #expect(wb.briefs.count == 2)
        #expect(wb.selected?.title.hasPrefix("Continue: Add retry") == true)
        #expect(wb.selected?.input.contains("Sources/Upload.swift") == true)
    }

    @Test("cancelling a continuation creates nothing")
    func continuationCancel() async {
        let wb = await workbench()
        let gate = AsyncGate()
        let m = model { await gate.wait(); return String(repeating: "A long enough summary sentence here. ", count: 3) }
        m.continueFromSession("session", in: wb)
        m.cancelContinuation()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(wb.briefs.count == 1)
        #expect(m.continuationPhase == .idle)
    }

    @Test("a failing continuation shows one sentence and creates nothing")
    func continuationFails() async {
        let wb = await workbench()
        let m = model { "ok" }
        m.continueFromSession("session", in: wb)
        await settleContinuation(m)
        #expect(m.continuationPhase == .failed(SidecarError.unusable.errorDescription!))
        #expect(wb.briefs.count == 1)
    }

    @Test("deleting the brief while a revise call runs applies nothing and leaves no stale cards")
    func deleteDuringRevise() async {
        let wb = await workbench()
        let gate = AsyncGate()
        let m = model { await gate.wait(); return "<revision>Better</revision>" }
        m.run(.revise, brief: wb.selected!, reply: "r")
        await wb.deleteSelected()
        await gate.open()
        await settle(m)
        if let r = m.result?.revisions.first { m.acceptRevision(r, in: wb) }
        #expect(wb.briefs.isEmpty)
    }


    @Test("accepting a finding sends one accepted signal with the guidance ids")
    func acceptSignals() async {
        let wb = await workbench()
        let sidecar = BriefSidecar(guidance: { _, _ in KnowledgeGuidance(text: "<guidance>\nx\n</guidance>\n", entryIDs: ["g1"]) },
                                   generate: { _ in "<findings>\n- No limit | add: Retry at most 3 times.\n- Vague\n</findings>" })
        let m = BriefSidecarModel(sidecar: sidecar)
        var signals: [(ids: [String], outcome: SignalOutcome)] = []
        m.onSignal = { signals.append(($0, $1)) }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        m.accept(m.result!.findings[0], in: wb)
        m.dismiss(findingID: m.result!.findings[0].id)
        #expect(signals.count == 1)
        #expect(signals.first?.outcome == .accepted && signals.first?.ids == ["g1"])
    }

    @Test("dismissing every card without accepting sends one rejected signal")
    func rejectSignals() async {
        let wb = await workbench()
        let sidecar = BriefSidecar(guidance: { _, _ in KnowledgeGuidance(text: "<guidance>\nx\n</guidance>\n", entryIDs: ["g1"]) },
                                   generate: { _ in "<findings>\n- Vague\n- Missing\n</findings>" })
        let m = BriefSidecarModel(sidecar: sidecar)
        var outcomes: [SignalOutcome] = []
        m.onSignal = { outcomes.append($1) }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        m.dismiss(findingID: m.result!.findings[0].id)
        #expect(outcomes.isEmpty)
        m.dismiss(findingID: m.result!.findings[0].id)
        #expect(outcomes == [.rejected])
    }

    @Test("no signal is sent when no guidance was used")
    func noSignalWithoutGuidance() async {
        let wb = await workbench()
        let m = model { "<findings>\n- Vague\n</findings>" }
        var count = 0
        m.onSignal = { _, _ in count += 1 }
        m.run(.critique, brief: wb.selected!)
        await settle(m)
        m.dismiss(findingID: m.result!.findings[0].id)
        #expect(count == 0)
    }

    @Test("accepting a revision reports the brief as accepted")
    func revisionAccepted() async {
        let wb = await workbench()
        let m = model { "<revision>Add retry with backoff to uploads</revision>" }
        var accepted = 0
        m.onAccepted = { _ in accepted += 1 }
        m.run(.revise, brief: wb.selected!, reply: "the answer")
        await settle(m)
        m.acceptRevision(m.result!.revisions[0], in: wb)
        #expect(accepted == 1)
    }

    @Test("sidecar answer while edited appends to body, not input")
    func answerToEditedBody() async {
        let wb = await workbench()
        wb.setBody("Edited body")
        let m = model { "<questions>\n- Which endpoint?\n</questions>" }
        m.run(.interview, brief: wb.selected!)
        await settle(m)
        m.answer(m.result!.questions[0], text: "/v1/upload", in: wb)
        #expect(wb.selected?.input == "Add retry to uploads")
        #expect(wb.selected?.body == "Edited body\n\nQ: Which endpoint?\nA: /v1/upload")
    }

}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}
