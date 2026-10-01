import Testing
@testable import KokoroCore

@Suite("Navigation")
struct NavigationTests {
    @Test("the sidebar leads with Briefs, and nothing else")
    func visibleDestinations() {
        #expect(NavDestination.sidebarPrimary == [.briefs, .prompts, .models])
        #expect(NavDestination.sidebarSecondary == [.settings])
    }

    @Test("labels follow the prompt-sidecar vocabulary")
    func labels() {
        #expect(NavDestination.briefs.label == "Briefs")
        #expect(NavDestination.prompts.label == "Library")
    }
}
