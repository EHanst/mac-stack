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

@Suite("RevealPacer")
struct RevealPacerTests {

    @Test("caught-up text moves at the base rate")
    func baseRate() {
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        p.advance(dt: 0.1, target: 30, streaming: true)   // backlog 30 -> 100/s, below base
        #expect(abs(p.position - RevealPacer.baseRate * 0.1) < 0.0001)
    }

    @Test("a growing backlog is drained faster than the base rate")
    func backlogSpeedsUp() {
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        p.advance(dt: 0.1, target: 90, streaming: true)   // backlog 90 -> 300/s
        #expect(p.position > RevealPacer.baseRate * 0.1)
    }

    @Test("speed keeps scaling with the backlog, with no cap")
    func uncapped() {
        var a = RevealPacer(elapsed: RevealPacer.rampDuration), b = RevealPacer(elapsed: RevealPacer.rampDuration)
        a.advance(dt: 0.1, target: 10_000, streaming: true)
        b.advance(dt: 0.1, target: 100_000, streaming: true)
        #expect(abs(a.rate - 10_000 / RevealPacer.maxLag) < 0.0001)
        #expect(b.rate > a.rate * 5)
    }

    @Test("never passes the target")
    func neverOvershoots() {
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        for _ in 0..<100 { p.advance(dt: 0.05, target: 20, streaming: true) }
        #expect(p.position == 20)
    }

    @Test("a stalled frame cannot jump the cursor")
    func stalledFrame() {
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        p.advance(dt: 5, target: 10_000, streaming: true)
        #expect(p.position <= 10_000 / RevealPacer.maxLag * RevealPacer.maxStep + 0.0001)
    }

    @Test("after the stream ends the tail settles faster than the base rate")
    func settles() {
        var live = RevealPacer(elapsed: RevealPacer.rampDuration), done = RevealPacer(elapsed: RevealPacer.rampDuration)
        live.advance(dt: 0.05, target: 200, streaming: true)
        done.advance(dt: 0.05, target: 200, streaming: false)
        #expect(done.position > live.position)
        #expect(done.rate >= RevealPacer.settleRate)
    }

    @Test("shorter replacement text pulls the cursor back")
    func shrinks() {
        var p = RevealPacer(position: 100, elapsed: RevealPacer.rampDuration)
        p.advance(dt: 0.016, target: 40, streaming: true)
        #expect(p.position == 40)
    }

    @Test("the fade edge stays within its range and grows with speed")
    func edge() {
        var slow = RevealPacer(elapsed: RevealPacer.rampDuration), fast = RevealPacer(elapsed: RevealPacer.rampDuration)
        slow.advance(dt: 0.016, target: 5, streaming: true)
        fast.advance(dt: 0.016, target: 10_000, streaming: true)
        #expect(RevealPacer.edgeRange.contains(slow.edgeWidth))
        #expect(RevealPacer.edgeRange.contains(fast.edgeWidth))
        #expect(fast.edgeWidth > slow.edgeWidth)
    }

    @Test("each glyph fades in over two seconds")
    func fadeIsTwoSeconds() {
        #expect(RevealPacer.fadeDuration == 2.0)
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        p.advance(dt: 0.016, target: 30, streaming: true)
        #expect(abs(p.edgeWidth / p.rate - 2.0) < 0.0001)
    }

    @Test("the cursor starts slow and speeds up to the backlog rate")
    func slowStartThenSpeedsUp() {
        var p = RevealPacer()
        p.advance(dt: 0.016, target: 10_000, streaming: true)
        #expect(p.rate < 60)
        var last = p.rate
        for _ in 0..<40 {
            p.advance(dt: 0.05, target: p.position + 10_000, streaming: true)   // a steady backlog
            #expect(p.rate >= last - 0.01)   // float noise
            last = p.rate
        }
        #expect(abs(p.rate - 10_000 / RevealPacer.maxLag) < 0.0001)
    }

    @Test("a new block after a pause restarts the slow start; a brief gap does not")
    func restartsAfterPause() {
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        p.advance(dt: 0.05, target: 5, streaming: true)
        for _ in 0..<10 { p.advance(dt: 0.05, target: 5, streaming: true) }   // caught up, 0.5s idle
        p.advance(dt: 0.016, target: 10_000, streaming: true)
        #expect(p.rate < 60)
        var q = RevealPacer(elapsed: RevealPacer.rampDuration)
        q.advance(dt: 0.05, target: 5, streaming: true)
        q.advance(dt: 0.05, target: 5, streaming: true)                        // 0.05s idle
        q.advance(dt: 0.016, target: 10_000, streaming: true)
        #expect(q.rate > 1_000)
    }

    @Test("the fade edge tightens while waiting for more text")
    func edgeTightensWhileWaiting() {
        var p = RevealPacer(elapsed: RevealPacer.rampDuration)
        p.advance(dt: 0.1, target: 10_000, streaming: true)
        let before = p.edgeWidth
        p.advance(dt: 0.1, target: p.position, streaming: true)
        for _ in 0..<20 { p.advance(dt: 0.1, target: p.position, streaming: true) }
        #expect(p.edgeWidth < before)
        #expect(abs(p.edgeWidth - RevealPacer.startRate * RevealPacer.fadeDuration) < 1)
    }
}

@Suite("RevealCurve")
struct RevealCurveTests {

    @Test("glyphs ahead of the cursor are invisible, far behind it fully visible")
    func ends() {
        #expect(RevealCurve.opacity(position: 10, index: 20, edge: 24) == 0)
        #expect(RevealCurve.opacity(position: 20.5, index: 20, edge: 24) >= RevealCurve.startOpacity)
        #expect(RevealCurve.opacity(position: 100, index: 20, edge: 24) == 1)
    }

    @Test("opacity rises monotonically across the edge, smoothly")
    func monotonic() {
        let values = (0...24).map { RevealCurve.opacity(position: 20 + Double($0), index: 20, edge: 24) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(abs(values[12] - (RevealCurve.startOpacity + (1 - RevealCurve.startOpacity) / 2)) < 0.0001)   // symmetric ease-in-out
        #expect(values[3] < 0.3 && values[21] > 0.9)   // gentle at both ends
    }
}
