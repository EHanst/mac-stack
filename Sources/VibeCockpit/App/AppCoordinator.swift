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
    public var intentHistory: [IntentEvent] = []
    public var currentDiff: UnifiedDiff?
    public var snapshotTimeline: [SnapshotRef] = []
    public var previewHTML: String?
    public var correctionLoopState: CorrectionLoopState = .init(maxRetries: 3)
    public var providerHealth: [ProviderID: ProviderHealth] = [:]
    public var modelInfos: [ModelInfo] = []
    public var indexingStatus: IndexingStatus = .init()
    public var mcpToolNames: [String] = []
    public var isGenerating: Bool = false
    public var onboardingNeeded: Bool = false
    public var activeIntent: String?

    public init() {}
}

public struct IntentEvent: Sendable, Identifiable {
    public enum Kind: Sendable {
        case userPrompt, assistantToken, toolCall, toolResult, error
    }
    public let id: UUID = UUID()
    public let kind: Kind
    public let content: String
    public let toolCallID: String?
    public let timestamp: Date = Date()

    public init(kind: Kind, content: String, toolCallID: String? = nil) {
        self.kind = kind
        self.content = content
        self.toolCallID = toolCallID
    }
}

/// Command/reducer app coordinator. The `reduce` function is pure and synchronous,
/// making state transitions unit-testable without any I/O mocks.
/// @MainActor isolation replaces the explicit OSAllocatedUnfairLock.
@MainActor
@Observable
public final class AppCoordinator {

    public enum Command: Sendable {
        case submitIntent(String)
        case tokenReceived(String)
        case toolCallMade(String, String, String)    // name, arguments, id
        case toolResultReceived(String, String)     // toolCallID, result
        case diffUpdated(UnifiedDiff)
        case snapshotCreated(SnapshotRef)
        case correctionNeeded(BuildResult)
        case correctionLoopReset
        case providerStatusChanged(ProviderID, ProviderHealth)
        case previewUpdated(String)
        case generationStarted
        case generationFinished
        case generationFailed(String)
        case onboardingRequired
        case onboardingCompleted
        // Model management
        case modelsRefreshed([ModelInfo])
        case modelHealthUpdated(ProviderID, ProviderHealth)
        // Indexing
        case indexingStatusUpdated(IndexingStatus)
        // MCP tools
        case mcpToolsUpdated([String])

        case clearSession
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
        case .submitIntent(let text):
            next.activeIntent = text
            next.currentDiff = nil
            next.intentHistory.append(IntentEvent(kind: .userPrompt, content: text))

        case .tokenReceived(let token):
            if let last = next.intentHistory.last, last.kind == .assistantToken {
                let combined = last.content + token
                next.intentHistory[next.intentHistory.count - 1] = IntentEvent(kind: .assistantToken, content: combined)
            } else {
                next.intentHistory.append(IntentEvent(kind: .assistantToken, content: token))
            }

        case .toolCallMade(let name, let args, let callID):
            next.intentHistory.append(IntentEvent(kind: .toolCall, content: "\(name)(\(args))", toolCallID: callID))

        case .toolResultReceived(let callID, let result):
            next.intentHistory.append(IntentEvent(kind: .toolResult, content: result, toolCallID: callID))

        case .diffUpdated(let diff):
            next.currentDiff = diff

        case .snapshotCreated(let ref):
            next.snapshotTimeline.insert(ref, at: 0)
            if next.snapshotTimeline.count > 50 {
                next.snapshotTimeline = Array(next.snapshotTimeline.prefix(50))
            }

        case .correctionNeeded(let result):
            let (action, newLoopState) = next.correctionLoopState.next(given: result)
            next.correctionLoopState = newLoopState
            switch action {
            case .retry:
                break
            case .surfaceToUser(let reason):
                next.intentHistory.append(IntentEvent(kind: .error, content: reason.description))
            }

        case .correctionLoopReset:
            next.correctionLoopState = CorrectionLoopState(maxRetries: next.correctionLoopState.maxRetries)

        case .providerStatusChanged(let id, let health):
            next.providerHealth[id] = health

        case .previewUpdated(let html):
            next.previewHTML = html

        case .generationStarted:
            next.isGenerating = true

        case .generationFinished:
            next.isGenerating = false

        case .generationFailed(let reason):
            next.intentHistory.append(IntentEvent(kind: .error, content: reason))

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

        case .clearSession:
            next.intentHistory = []
            next.currentDiff = nil
            next.previewHTML = nil
            next.activeIntent = nil
            next.correctionLoopState = .init(maxRetries: next.correctionLoopState.maxRetries)
        }
        return next
    }
}
