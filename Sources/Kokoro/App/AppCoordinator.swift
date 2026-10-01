import Foundation
import Observation
import os
#if SWIFT_PACKAGE
import StackCore
#endif

// Lightweight descriptor for the model manager UI — no actor reference crossing.
public struct ModelInfo: Sendable, Identifiable {
    public enum Kind: Sendable { case local, remote }
    public let id: ProviderID
    public let displayName: String
    public let kind: Kind
    public let capabilities: ProviderCapabilities
    public var health: ProviderHealth
    public var isLoaded: Bool

    public init(
        id: ProviderID,
        displayName: String,
        kind: Kind,
        capabilities: ProviderCapabilities,
        health: ProviderHealth,
        isLoaded: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.capabilities = capabilities
        self.health = health
        self.isLoaded = isLoaded
    }
}

public struct IndexingStatus: Sendable {
    public var isRunning: Bool = false
    public var filesIndexed: Int = 0
    public var totalFiles: Int = 0

    public init() {}

    public var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(filesIndexed) / Double(totalFiles)
    }
}

public struct AppState: Sendable {
    public var providerHealth: [ProviderID: ProviderHealth] = [:]
    public var modelInfos: [ModelInfo] = []
    public var indexingStatus: IndexingStatus = .init()
    public var mcpToolNames: [String] = []
    public var onboardingNeeded: Bool = false

    public init() {}
}

/// Command/reducer app coordinator. The `reduce` function is pure and synchronous,
/// making state transitions unit-testable without any I/O mocks.
/// @MainActor isolation replaces the explicit OSAllocatedUnfairLock.
@MainActor
@Observable
public final class AppCoordinator {

    public enum Command: Sendable {
        case providerStatusChanged(ProviderID, ProviderHealth)
        case onboardingRequired
        case onboardingCompleted
        // Model management
        case modelsRefreshed([ModelInfo])
        case modelHealthUpdated(ProviderID, ProviderHealth)
        // Indexing
        case indexingStatusUpdated(IndexingStatus)
        // MCP tools
        case mcpToolsUpdated([String])
    }

    public private(set) var state: AppState
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppCoordinator")

    public init(initialState: AppState = .init()) {
        self.state = initialState
    }

    public func send(_ command: Command) {
        state = AppCoordinator.reduce(state, command)
    }

    // MARK: - Pure reducer (nonisolated so unit tests can call it synchronously)

    public nonisolated static func reduce(_ state: AppState, _ command: Command) -> AppState {
        var next = state
        switch command {
        case .providerStatusChanged(let id, let health):
            next.providerHealth[id] = health

        case .onboardingRequired:
            next.onboardingNeeded = true

        case .onboardingCompleted:
            next.onboardingNeeded = false

        case .modelsRefreshed(let infos):
            next.modelInfos = infos

        case .modelHealthUpdated(let id, let health):
            if let idx = next.modelInfos.firstIndex(where: { $0.id == id }) {
                next.modelInfos[idx].health = health
            }
            next.providerHealth[id] = health

        case .indexingStatusUpdated(let status):
            next.indexingStatus = status

        case .mcpToolsUpdated(let names):
            next.mcpToolNames = names
        }
        return next
    }
}
