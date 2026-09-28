import Testing
import Foundation
@testable import VibeCockpitCore

@Suite("AppCoordinator reducer")
struct AppCoordinatorTests {

    @Test("submitIntent sets activeIntent and adds to history")
    func submitIntent() {
        let state = AppCoordinator.reduce(.init(), .submitIntent("add unit tests"))
        #expect(state.activeIntent == "add unit tests")
        #expect(state.intentHistory.count == 1)
        #expect(state.intentHistory.first?.kind == .userPrompt)
    }

    @Test("tokenReceived appends to last assistant event")
    func appendsTokens() {
        var state = AppCoordinator.reduce(.init(), .generationStarted)
        state = AppCoordinator.reduce(state, .tokenReceived("Hello"))
        state = AppCoordinator.reduce(state, .tokenReceived(", world"))
        #expect(state.intentHistory.last?.content == "Hello, world")
        #expect(state.intentHistory.count == 1)
    }

    @Test("snapshotCreated inserts at front and caps at 50")
    func snapshotCap() {
        var state = AppState()
        for _ in 0..<55 {
            let ref = SnapshotRef(id: UUID(), oid: "abc", message: "snap",
                                  createdAt: .now, branchName: "branch")
            state = AppCoordinator.reduce(state, .snapshotCreated(ref))
        }
        #expect(state.snapshotTimeline.count == 50)
    }

    @Test("onboarding required / completed round trip")
    func onboarding() {
        var state = AppCoordinator.reduce(.init(), .onboardingRequired)
        #expect(state.onboardingNeeded == true)
        state = AppCoordinator.reduce(state, .onboardingCompleted)
        #expect(state.onboardingNeeded == false)
    }
}
