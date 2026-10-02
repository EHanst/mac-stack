#if canImport(AppKit)
import SwiftUI

/// The chibi Kokoro that "types" the text: a round-cheeked heart with big eyes, drawn with paths so
/// there is nothing to load. `phase` (the reveal position) drives a small bob and tilt.
enum KokoroCursor {
    static let body = Color(red: 1.0, green: 0.45, blue: 0.58)
    static let shade = Color(red: 0.86, green: 0.27, blue: 0.43)

    /// Draws the mascot centered on `center`, `size` points tall.
    static func draw(in context: inout GraphicsContext, center: CGPoint, size: CGFloat, phase: Double) {
        var c = context
        let bob = CGFloat(sin(phase * 0.45)) * size * 0.07
        c.translateBy(x: center.x, y: center.y + bob)
        c.rotate(by: .radians(sin(phase * 0.3) * 0.12))
        let u = size / 2

        // Heart body: two lobes and a point, soft outline underneath for depth.
        var heart = Path()
        heart.move(to: CGPoint(x: 0, y: u * 0.95))
        heart.addCurve(to: CGPoint(x: -u * 1.0, y: -u * 0.15),
                       control1: CGPoint(x: -u * 0.35, y: u * 0.7), control2: CGPoint(x: -u * 1.0, y: u * 0.3))
        heart.addCurve(to: CGPoint(x: 0, y: -u * 0.5),
                       control1: CGPoint(x: -u * 1.0, y: -u * 0.85), control2: CGPoint(x: -u * 0.2, y: -u * 0.95))
        heart.addCurve(to: CGPoint(x: u * 1.0, y: -u * 0.15),
                       control1: CGPoint(x: u * 0.2, y: -u * 0.95), control2: CGPoint(x: u * 1.0, y: -u * 0.85))
        heart.addCurve(to: CGPoint(x: 0, y: u * 0.95),
                       control1: CGPoint(x: u * 1.0, y: u * 0.3), control2: CGPoint(x: u * 0.35, y: u * 0.7))
        heart.closeSubpath()
        c.fill(heart.offsetBy(dx: 0, dy: u * 0.08), with: .color(shade))
        c.fill(heart, with: .color(body))

        // Highlight.
        c.fill(Path(ellipseIn: CGRect(x: -u * 0.62, y: -u * 0.5, width: u * 0.3, height: u * 0.18)),
               with: .color(.white.opacity(0.55)))

        // Eyes (with a blink every so often), blush and a tiny smile.
        let blink = Int(phase / 9) % 3 == 0 && Int(phase) % 9 < 1
        for side in [-1.0, 1.0] {
            let x = CGFloat(side) * u * 0.38
            if blink {
                var lid = Path()
                lid.move(to: CGPoint(x: x - u * 0.12, y: u * 0.0))
                lid.addLine(to: CGPoint(x: x + u * 0.12, y: u * 0.0))
                c.stroke(lid, with: .color(.black.opacity(0.8)), lineWidth: max(1, u * 0.07))
            } else {
                c.fill(Path(ellipseIn: CGRect(x: x - u * 0.12, y: -u * 0.14, width: u * 0.24, height: u * 0.32)),
                       with: .color(.black.opacity(0.85)))
                c.fill(Path(ellipseIn: CGRect(x: x - u * 0.06, y: -u * 0.1, width: u * 0.1, height: u * 0.1)),
                       with: .color(.white))
            }
            c.fill(Path(ellipseIn: CGRect(x: x - u * 0.18 + CGFloat(side) * u * 0.14, y: u * 0.26, width: u * 0.26, height: u * 0.14)),
                   with: .color(.white.opacity(0.4)))
        }
        var smile = Path()
        smile.move(to: CGPoint(x: -u * 0.1, y: u * 0.3))
        smile.addQuadCurve(to: CGPoint(x: u * 0.1, y: u * 0.3), control: CGPoint(x: 0, y: u * 0.46))
        c.stroke(smile, with: .color(.black.opacity(0.75)), lineWidth: max(1, u * 0.06))
    }
}
#endif
