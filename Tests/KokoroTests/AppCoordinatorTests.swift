import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore

@Suite("AppCoordinator reducer")
struct AppCoordinatorTests {
    @Test("onboarding required / completed round trip")
    func onboarding() {
        var state = AppCoordinator.reduce(.init(), .onboardingRequired)
        #expect(state.onboardingNeeded == true)
        state = AppCoordinator.reduce(state, .onboardingCompleted)
        #expect(state.onboardingNeeded == false)
    }
}
