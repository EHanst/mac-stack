import Testing
@testable import KokoroCore

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

@Suite("AppFont")
struct AppFontTests {

    @Test("Osaka is the default; unknown values fall back to it")
    func defaults() {
        #expect(AppFont.default == .osaka)
        #expect(AppFont(stored: nil) == .osaka)
        #expect(AppFont(stored: "comic-sans") == .osaka)
        #expect(AppFont(stored: "skia") == .skia)
    }

    @Test("the six options, Osaka first; only the named faces have a family")
    func options() {
        #expect(AppFont.allCases == [.osaka, .skia, .system, .rounded, .serif, .mono])
        #expect(AppFont.allCases.compactMap(\.familyName) == ["Osaka", "Skia"])
    }
}
