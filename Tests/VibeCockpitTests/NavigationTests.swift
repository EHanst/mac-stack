import Testing
@testable import VibeCockpitCore

@Suite("Navigation")
struct NavigationTests {
    @Test("the sidebar leads with Briefs, keeps chat as Quick ask, and hides the IDE panes")
    func visibleDestinations() {
        #expect(NavDestination.sidebarPrimary == [.briefs, .prompts, .models])
        #expect(NavDestination.sidebarSecondary == [.chat, .tools, .settings])
        let shown = NavDestination.sidebarPrimary + NavDestination.sidebarSecondary
        #expect(!shown.contains(.diff) && !shown.contains(.snapshots))
    }

    @Test("labels follow the prompt-sidecar vocabulary")
    func labels() {
        #expect(NavDestination.briefs.label == "Briefs")
        #expect(NavDestination.prompts.label == "Library")
        #expect(NavDestination.chat.label == "Quick ask")
    }

    @Test("the hidden panes still exist, so nothing they own is deleted")
    func stillDefined() {
        #expect(NavDestination.allCases.contains(.diff) && NavDestination.allCases.contains(.snapshots))
    }
}
