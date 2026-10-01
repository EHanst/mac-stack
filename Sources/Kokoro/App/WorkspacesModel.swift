import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
import StackMCP
#endif

/// Settings view of the projects the user added.
@MainActor
@Observable
public final class WorkspacesModel {
    public struct Row: Identifiable, Equatable {
        public let record: WorkspaceRecord
        public let status: WorkspaceStatus
        public var id: String { record.id }
    }
    public private(set) var rows: [Row] = []
    public private(set) var lastError: String?
    private let manager: WorkspaceManager

    public init(manager: WorkspaceManager) {
        self.manager = manager
        Task { [weak self] in
            await manager.setChangeHandler { Task { @MainActor in await self?.reload() } }
            await self?.reload()
        }
    }

    public func reload() async {
        rows = await manager.list.map { Row(record: $0.record, status: $0.status) }
    }

    public func add(_ folder: URL) async {
        lastError = nil
        do { try await manager.add(folder) } catch { lastError = error.localizedDescription }
        await reload()
    }

    public func remove(_ id: String) async { await manager.remove(id); await reload() }

    public nonisolated static func statusText(_ s: WorkspaceStatus) -> String {
        switch s {
        case .opening: "Opening…"
        case .ready: "Ready"
        case .failed(let why): "Couldn't open: \(why)"
        }
    }
}
