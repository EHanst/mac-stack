import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore

private func ask(_ name: String = "Cursor") -> ApprovalRequest {
    ApprovalRequest(client: ClientIdentity(key: "client:\(name)", name: name), toolName: "write_file", scope: .toolsWrite, summary: "Write /a.txt")
}

@MainActor
private func waitForPending(_ center: ApprovalCenter, _ n: Int) async throws {
    for _ in 0..<100 { if center.pending.count == n { return }; try await Task.sleep(for: .milliseconds(10)) }
    Issue.record("expected \(n) pending, have \(center.pending.count)")
}

@Suite("ApprovalCenter")
@MainActor
struct ApprovalCenterTests {

    @Test("a question waits until it is answered, and the answer is delivered")
    func answered() async throws {
        let center = ApprovalCenter()
        let request = ask()
        var attention = 0
        center.onNeedsAttention = { attention += 1 }
        let answer = Task { await center.decide(request) }
        try await waitForPending(center, 1)
        #expect(center.pending.first == request)
        #expect(attention == 1)
        center.resolve(request.id, .allowAlways)
        #expect(await answer.value == .allowAlways)
        #expect(center.pending.isEmpty)
    }

    @Test("several questions queue in order and are answered independently")
    func queue() async throws {
        let center = ApprovalCenter()
        let a = ask("A"), b = ask("B")
        let ta = Task { await center.decide(a) }
        try await waitForPending(center, 1)
        let tb = Task { await center.decide(b) }
        try await waitForPending(center, 2)
        #expect(center.pending.map(\.client.name) == ["A", "B"])
        center.resolve(b.id, .deny)
        center.resolve(a.id, .allowOnce)
        #expect(await ta.value == .allowOnce)
        #expect(await tb.value == .deny)
    }

    @Test("an unanswered question is a no after the timeout")
    func timesOut() async throws {
        let center = ApprovalCenter(timeout: .milliseconds(50))
        #expect(await center.decide(ask()) == .deny)
        #expect(center.pending.isEmpty)
    }

    @Test("if the asking app goes away the question disappears")
    func cancelled() async throws {
        let center = ApprovalCenter()
        let task = Task { await center.decide(ask()) }
        try await waitForPending(center, 1)
        task.cancel()
        #expect(await task.value == .deny)
        try await waitForPending(center, 0)
    }

    @Test("answering twice or an unknown id does nothing")
    func idempotent() async throws {
        let center = ApprovalCenter()
        let request = ask()
        let task = Task { await center.decide(request) }
        try await waitForPending(center, 1)
        center.resolve(request.id, .allowOnce)
        center.resolve(request.id, .deny)
        center.resolve(UUID(), .deny)
        #expect(await task.value == .allowOnce)
    }

    @Test("saved approvals can be listed and forgotten")
    func saved() async {
        struct Mem: ApprovalStore {
            func load() throws -> [String: SavedApproval] { [:] }
            func save(_ a: [String: SavedApproval]) throws {}
        }
        let memory = ApprovalMemory(store: Mem())
        await memory.remember(ClientIdentity(key: "k", name: "Zed"), .toolsExec)
        let model = SavedApprovalsModel(memory: memory)
        await model.reload()
        #expect(model.rows.map(\.name) == ["Zed"])
        await model.forget(model.rows[0])
        #expect(model.rows.isEmpty)
    }
}
