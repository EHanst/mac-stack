#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

/// Draws each glyph at the opacity `RevealCurve` gives it for the cursor position. Text keeps its
/// final layout the whole time, so nothing reflows; only glyph opacity changes. Fading a glyph
/// in over the surface behind it is the same as blending from that surface's color to the text
/// color, in light and dark alike.
struct RevealRenderer: TextRenderer, Animatable {
    var position: Double
    var edge: Double

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        var shadowed: [(glyph: Text.Layout.RunSlice, strength: Double)] = []
        var cursor: CGRect?
        for line in layout {
            for run in line {
                for glyph in run {
                    let alpha = RevealCurve.opacity(position: position, index: index, edge: edge)
                    if cursor == nil, index >= position.rounded(.down) { cursor = glyph.typographicBounds.rect }
                    index += 1
                    guard alpha > 0 else { continue }
                    // A glow that is strongest while a glyph is half-faded and gone once it has landed.
                    let strength = 4 * alpha * (1 - alpha) * 0.5
                    if strength > 0.02 { shadowed.append((glyph, strength)) }
                    var glyphContext = context
                    glyphContext.opacity = alpha
                    glyphContext.draw(glyph)
                }
            }
        }
        // One blurred layer for every glyph still fading, so the trail costs a single filter.
        if !shadowed.isEmpty {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                for (glyph, strength) in shadowed {
                    var g = layer
                    g.opacity = strength
                    g.draw(glyph)
                }
            }
        }
        if let cursor, position < index {
            let size = max(cursor.height * 1.15, 14)
            KokoroCursor.draw(in: &context, center: CGPoint(x: cursor.minX - size * 0.35, y: cursor.midY),
                              size: size, phase: position)
        }
    }
}

/// Owns the reveal cursor and steps it once a frame while there is something left to show.
@MainActor @Observable
final class RevealDriver {
    private(set) var position: Double
    private(set) var edge: Double = RevealPacer.edgeRange.lowerBound
    var count: Int
    var live: Bool
    private var pacer: RevealPacer
    private let showAll: Bool

    /// `startRevealed`: finished text (history) is shown at once and never animates.
    init(count: Int, live: Bool) {
        self.count = count
        self.live = live
        showAll = !live
        pacer = RevealPacer(position: live ? 0 : .greatestFiniteMagnitude)
        position = live ? 0 : .greatestFiniteMagnitude
    }

    private var target: Double { live ? Double(count) : pacer.finishTarget(count: count) }
    var isSettled: Bool { !live && (showAll || pacer.position >= target) }

    func run() async {
        guard !showAll else { return }
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            if isSettled { return }
            try? await clock.sleep(for: .milliseconds(8))
            let now = clock.now
            let dt = (now - last) / .seconds(1)
            last = now
            pacer.advance(dt: dt, target: target, streaming: live)
            position = pacer.position
            edge = pacer.edgeWidth
        }
    }
}

/// Streamed reply text: fades in glyph by glyph, left to right, at a steady, snappy pace.
/// `live` is true while the model is still producing this reply; when it turns false the tail
/// finishes quickly. Completed text (`live` false from the start) is shown plainly.
struct StreamRevealText: View {
    let text: String
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var driver: RevealDriver

    init(_ text: String, live: Bool) {
        self.text = text
        self.live = live
        _driver = State(initialValue: RevealDriver(count: text.count, live: live))
    }

    var body: some View {
        Group {
            if reduceMotion || driver.isSettled {
                Text(text)
            } else {
                Text(text).textRenderer(RevealRenderer(position: driver.position, edge: driver.edge))
            }
        }
        .onChange(of: text) { driver.count = text.count }
        .onChange(of: live) { driver.live = live }
        .task(id: live) { await driver.run() }
    }
}
#endif
