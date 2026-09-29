import Testing
@testable import VibeCockpitCore

@Suite("AppTheme")
struct AppThemeTests {

    @Test("stored values round-trip")
    func roundTrip() {
        for theme in AppTheme.allCases {
            #expect(AppTheme(stored: theme.rawValue) == theme)
        }
    }

    @Test("missing or unknown values follow the system")
    func fallback() {
        #expect(AppTheme(stored: nil) == .system)
        #expect(AppTheme(stored: "") == .system)
        #expect(AppTheme(stored: "sepia") == .system)
    }

    @Test("all three choices are offered, system first")
    func choices() {
        #expect(AppTheme.allCases == [.system, .light, .dark])
        #expect(AppTheme.default == .system)
    }
}
