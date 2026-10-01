import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Holds "an app wants to change your files / run a command" questions until the user answers.
/// The MCP host awaits `decide`; the UI shows `pending` and calls `resolve`.
@MainActor
@Observable
public final class ApprovalCenter: ToolApprover {

    public private(set) var pending: [ApprovalRequest] = []
    /// Called when a question arrives, so the app can come to the front (it may be in the menu bar).
    public var onNeedsAttention: (@MainActor () -> Void)?

    private var waiters: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private let timeout: Duration

    /// An unanswered question is a "no" after `timeout` — nobody is left waiting forever.
    public init(timeout: Duration = .seconds(120)) { self.timeout = timeout }

    public nonisolated func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withTaskCancellationHandler {
            await self.enqueue(request)
        } onCancel: {
            Task { @MainActor in self.resolve(request.id, .deny) }   // the app gave up (disconnected)
        }
    }

    private func enqueue(_ request: ApprovalRequest) async -> ApprovalDecision {
        if Task.isCancelled { return .deny }
        return await withCheckedContinuation { continuation in
            waiters[request.id] = continuation
            pending.append(request)
            onNeedsAttention?()
            let wait = timeout
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                self?.resolve(request.id, .deny)
            }
        }
    }

    public func resolve(_ id: UUID, _ decision: ApprovalDecision) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: decision)
    }
}

/// Settings view of the "always allow" choices.
@MainActor
@Observable
public final class SavedApprovalsModel {
    public struct Row: Identifiable, Equatable {
        public let key: String
        public let name: String
        public let scopes: [ClientScope]
        public var id: String { key }
    }
    public private(set) var rows: [Row] = []
    private let memory: ApprovalMemory

    public init(memory: ApprovalMemory) { self.memory = memory }

    public func reload() async {
        rows = await memory.all.map { Row(key: $0.key, name: $0.entry.name, scopes: $0.entry.scopes.sorted { $0.rawValue < $1.rawValue }) }
    }

    public func forget(_ row: Row, scope: ClientScope? = nil) async {
        if let scope { await memory.forget(key: row.key, scope: scope) } else { await memory.forget(key: row.key) }
        await reload()
    }
}
