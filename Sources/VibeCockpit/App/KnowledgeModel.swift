import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// The opt-in, the "N briefs learned" chip and the Knowledge pane's data.
@MainActor
@Observable
public final class KnowledgeModel {
    public private(set) var decision: KnowledgeSettings.Decision
    public private(set) var prompt: KnowledgeSettings.Prompt?
    public private(set) var counts: [KnowledgeKind: Int] = [:]
    public private(set) var entries: [KnowledgeEntry] = []
    public private(set) var packs: [KnowledgePackSummary] = []
    public private(set) var error: String?
    public var learnedCount: Int { counts[.exemplar] ?? 0 }

    @ObservationIgnored public let recorder: KnowledgeRecorder
    @ObservationIgnored public let retriever: KnowledgeRetriever
    @ObservationIgnored private let store: KnowledgeStore
    @ObservationIgnored private let settings: KnowledgeSettings

    public init(store: KnowledgeStore, settings: KnowledgeSettings = KnowledgeSettings()) {
        self.store = store; self.settings = settings
        self.recorder = KnowledgeRecorder(store: store, settings: settings)
        self.retriever = KnowledgeRetriever(store: store)
        self.decision = settings.decision
        self.prompt = settings.prompt
    }

    public func refresh() async {
        decision = settings.decision
        prompt = settings.prompt
        do {
            counts = try await store.counts()
            entries = try await store.all(limit: 200)
            packs = try await store.packSummaries()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func turnOn() async { settings.setDecision(.enabled); await refresh() }
    public func turnOff() async { settings.setDecision(.declined); await refresh() }
    public func dismissCard() { settings.dismissCard(); prompt = settings.prompt }
    public func dismissNudge() { settings.dismissNudge(); prompt = settings.prompt }

    public func noteAccepted(_ brief: Brief) async { await recorder.recordAccepted(brief); await refresh() }
    public func noteSignal(ids: [String], outcome: SignalOutcome) async {
        await recorder.recordSignal(ids: ids, outcome: outcome)
    }

    public func delete(id: String) async { await change { try await $0.delete(ids: [id]) } }
    public func setEnabled(_ on: Bool, id: String) async { await change { try await $0.setEnabled(on, id: id) } }
    public func setPackEnabled(_ on: Bool, pack: String) async { await change { try await $0.setPackEnabled(on, pack: pack) } }
    public func wipeLearned() async { await change { try await $0.wipeHistory() } }

    private func change(_ op: (KnowledgeStore) async throws -> Void) async {
        do { try await op(store) } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
