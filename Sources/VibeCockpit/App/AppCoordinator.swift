import Foundation
import Observation
import os

public struct AppState: Sendable {
    public var intentHistory: [IntentEvent] = []
    public var currentDiff: UnifiedDiff?
    public var snapshotTimeline: [SnapshotRef] = []
    public var previewHTML: String?
    public var correctionLoopState: CorrectionLoopState = .init(maxRetries: 3)
    public var providerHealth: [ProviderID: ProviderHealth] = [:]
    public var isGenerating: Bool = false
    public var onboardingNeeded: Bool = false
    public var activeIntent: String?

    public init() {}
}

public struct IntentEvent: Sendable, Identifiable {
    public enum Kind: Sendable { case userPrompt, assistantToken, toolCall, error }
    public let id: UUID = UUID()
    public let kind: Kind
    public let content: String
    public let timestamp: Date = Date()

    public init(kind: Kind, content: String) {
        self.kind = kind
        self.content = content
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
        case toolCallMade(String, String)           // name, arguments
        case diffUpdated(UnifiedDiff)
        case snapshotCreated(SnapshotRef)
        case correctionNeeded(BuildResult)
        case correctionLoopReset
        case providerStatusChanged(ProviderID, ProviderHealth)
        case previewUpdated(String)
        case generationStarted
        case generationFinished
        case onboardingRequired
        case onboardingCompleted
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

        case .toolCallMade(let name, let args):
            next.intentHistory.append(IntentEvent(kind: .toolCall, content: "\(name)(\(args))"))

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

        case .onboardingRequired:
            next.onboardingNeeded = true

        case .onboardingCompleted:
            next.onboardingNeeded = false
        }
        return next
    }
}
