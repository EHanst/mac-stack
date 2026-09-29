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

@Suite("RevealPacer")
struct RevealPacerTests {

    @Test("caught-up text moves at the base rate")
    func baseRate() {
        var p = RevealPacer()
        p.advance(dt: 0.1, target: 30, streaming: true)   // backlog 30 -> 100/s, below base
        #expect(abs(p.position - RevealPacer.baseRate * 0.1) < 0.0001)
    }

    @Test("a growing backlog is drained faster than the base rate")
    func backlogSpeedsUp() {
        var p = RevealPacer()
        p.advance(dt: 0.1, target: 90, streaming: true)   // backlog 90 -> 300/s
        #expect(p.position > RevealPacer.baseRate * 0.1)
    }

    @Test("a large backlog is capped at the max rate")
    func maxRate() {
        var p = RevealPacer()
        p.advance(dt: 0.1, target: 10_000, streaming: true)
        #expect(abs(p.position - RevealPacer.maxRate * 0.1) < 0.0001)
    }

    @Test("never passes the target")
    func neverOvershoots() {
        var p = RevealPacer()
        for _ in 0..<100 { p.advance(dt: 0.05, target: 20, streaming: true) }
        #expect(p.position == 20)
    }

    @Test("a stalled frame cannot jump the cursor")
    func stalledFrame() {
        var p = RevealPacer()
        p.advance(dt: 5, target: 10_000, streaming: true)
        #expect(p.position <= RevealPacer.maxRate * RevealPacer.maxStep + 0.0001)
    }

    @Test("after the stream ends the tail settles faster than the base rate")
    func settles() {
        var live = RevealPacer(), done = RevealPacer()
        live.advance(dt: 0.05, target: 200, streaming: true)
        done.advance(dt: 0.05, target: 200, streaming: false)
        #expect(done.position > live.position)
        #expect(done.rate >= RevealPacer.settleRate)
    }

    @Test("shorter replacement text pulls the cursor back")
    func shrinks() {
        var p = RevealPacer(position: 100)
        p.advance(dt: 0.016, target: 40, streaming: true)
        #expect(p.position == 40)
    }

    @Test("the fade edge stays within its range and grows with speed")
    func edge() {
        var slow = RevealPacer(), fast = RevealPacer()
        slow.advance(dt: 0.016, target: 5, streaming: true)
        fast.advance(dt: 0.016, target: 10_000, streaming: true)
        #expect(RevealPacer.edgeRange.contains(slow.edgeWidth))
        #expect(RevealPacer.edgeRange.contains(fast.edgeWidth))
        #expect(fast.edgeWidth > slow.edgeWidth)
    }
}

@Suite("RevealCurve")
struct RevealCurveTests {

    @Test("glyphs ahead of the cursor are invisible, far behind it fully visible")
    func ends() {
        #expect(RevealCurve.opacity(position: 10, index: 20, edge: 24) == 0)
        #expect(RevealCurve.opacity(position: 100, index: 20, edge: 24) == 1)
    }

    @Test("opacity rises monotonically across the edge, ease-out")
    func monotonic() {
        let values = (0...24).map { RevealCurve.opacity(position: 20 + Double($0), index: 20, edge: 24) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values[12] > 0.5)   // ease-out: past halfway by the midpoint
    }
}
