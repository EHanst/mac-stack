import Foundation

/// Paces how fast streamed text is *shown*, independent of how fast the model *sends* it.
///
/// Tokens arrive in bursts; showing them as they land looks choppy. The pacer keeps a cursor
/// (in glyphs) that chases the amount of text available: steady at `baseRate`, faster as the
/// backlog grows (draining it with a `maxLag` time constant, up to `maxRate`), and quicker again
/// once the stream has ended so the tail finishes promptly. Pure, so every rule is unit-tested.
public struct RevealPacer: Equatable, Sendable {
    public static let baseRate = 110.0      // glyphs/second when caught up: snappy, still visible
    public static let maxRate = 400.0
    public static let maxLag = 0.30         // seconds; time constant for draining a backlog
    public static let settleRate = 700.0    // once the stream has ended
    public static let fadeDuration = 9.0    // seconds each glyph takes to fade in
    public static let edgeRange = 240.0...4000.0
    public static let maxStep = 0.1         // a stalled frame never jumps the cursor further than this

    /// Cursor position, in glyphs from the start of the text.
    public private(set) var position: Double
    /// Rate used on the last step; the soft edge scales with it so every glyph fades for
    /// about `fadeDuration` however fast the text is moving.
    public private(set) var rate: Double = RevealPacer.baseRate

    public init(position: Double = 0) { self.position = position }

    /// Width of the leading fade, in glyphs.
    public var edgeWidth: Double {
        min(max(rate * Self.fadeDuration, Self.edgeRange.lowerBound), Self.edgeRange.upperBound)
    }

    /// Moves the cursor toward `target` (the glyph count to reveal up to) by `dt` seconds.
    public mutating func advance(dt: Double, target: Double, streaming: Bool) {
        let step = min(max(dt, 0), Self.maxStep)
        let backlog = target - position
        guard backlog > 0 else {
            if backlog < 0 { position = target }    // text got shorter (replaced): never overshoot
            return
        }
        var next = min(max(Self.baseRate, backlog / Self.maxLag), Self.maxRate)
        if !streaming { next = max(next, Self.settleRate) }
        rate = next
        position = min(target, position + next * step)
    }

    /// The glyph count the cursor must reach before the reveal is fully done: once the stream
    /// ends it runs `edgeWidth` past the end so the last glyphs finish fading.
    public func finishTarget(count: Int) -> Double { Double(count) + edgeWidth }
}

/// Per-glyph opacity for a cursor position: a wide, soft leading edge on a smooth ease-in-out.
/// Glyphs reveal from the surface they sit on (opacity 0) to their text color (opacity 1),
/// so it reads the same in light and dark themes.
public enum RevealCurve {
    public static func opacity(position: Double, index: Double, edge: Double) -> Double {
        guard edge > 0 else { return position > index ? 1 : 0 }
        let t = min(max((position - index) / edge, 0), 1)
        return t * t * (3 - 2 * t)      // smoothstep: gentle start and finish, so the fade is visible
    }
}
