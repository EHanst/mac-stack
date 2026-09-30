import Testing
@testable import VibeCockpitCore

@Suite("Navigation")
struct NavigationTests {
    @Test("the sidebar leads with Chat and Prompts and hides the IDE panes")
    func visibleDestinations() {
        let shown = NavDestination.sidebarPrimary + NavDestination.sidebarSecondary
        #expect(NavDestination.sidebarPrimary.first == .chat)
        #expect(shown.contains(.prompts) && shown.contains(.models) && shown.contains(.settings))
        #expect(!shown.contains(.diff) && !shown.contains(.snapshots))
    }

    @Test("the hidden panes still exist, so nothing they own is deleted")
    func stillDefined() {
        #expect(NavDestination.allCases.contains(.diff) && NavDestination.allCases.contains(.snapshots))
    }
}
