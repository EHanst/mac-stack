import Testing
import Foundation
@testable import KororoCore
@testable import StackCore

@Suite("CloudUsageModel")
@MainActor
struct CloudUsageModelTests {
    private struct Mem: EgressStore {
        func load() -> EgressState { EgressState() }
        func save(_ s: EgressState) {}
    }

    @Test("shows usage, limit and the newest ledger line first, in plain words")
    func reload() async throws {
        let gate = EgressGate(policy: .localFirst, store: Mem())
        let model = CloudUsageModel(gate: gate)
        try await gate.authorize(.modelDownload, url: URL(string: "https://example.com/x")!)
        try await gate.authorize(.cloudInference, url: URL(string: "https://api.openai.com/v1/chat")!, provider: "openai")
        await gate.recordCloudTokens(1_500)
        await model.setCap(10_000)
        #expect(model.tokensThisMonth == 1_500 && model.monthlyTokenCap == 10_000)
        #expect(model.entries.map(CloudUsageModel.describe) == ["Question to openai → api.openai.com", "Model download → example.com"])
        await model.setCap(nil)
        #expect(model.monthlyTokenCap == nil)
        await model.clearLedger()
        #expect(model.entries.isEmpty)
    }

    @Test("blocked requests say so")
    func blocked() async {
        let gate = EgressGate(policy: .localOnly, store: Mem())
        try? await gate.authorize(.cloudInference, url: URL(string: "https://api.openai.com")!, provider: "openai")
        let model = CloudUsageModel(gate: gate)
        await model.reload()
        #expect(model.entries.map(CloudUsageModel.describe) == ["Blocked: Question to openai to api.openai.com"])
    }
}
