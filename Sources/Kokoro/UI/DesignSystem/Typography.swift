#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import AppKit
import SwiftUI

/// Resolves the user's typeface choice into SwiftUI fonts. The `Font.mt*` scale calls this, so
/// changing the choice changes every size at once. If a named face isn't installed the system
/// font is used instead.
enum AppTypography {
    /// Read at draw time; the root re-identifies the panels when the choice changes.
    static var current: AppFont {
        AppFont(stored: UserDefaults.standard.string(forKey: AppFont.storageKey))
    }

    /// Ratio of the system's preferred body size to macOS's default 13pt, so text follows the
    /// user's system text-size setting. Read at draw time like `current`.
    static var scale: CGFloat {
        max(0.5, NSFont.preferredFont(forTextStyle: .body).pointSize / 13)
    }

    static func scaled(_ size: CGFloat) -> CGFloat { size * scale }

    /// Monospaced at a size that follows the system text-size setting, for code and machine text.
    static func monoFont(size: CGFloat) -> Font {
        .system(size: scaled(size), design: .monospaced)
    }

    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        font(current, size: size, weight: weight)
    }

    static func font(_ choice: AppFont, size rawSize: CGFloat, weight: Font.Weight) -> Font {
        let size = scaled(rawSize)
        switch choice {
        case .osaka, .skia:
            if let family = choice.familyName, NSFont(name: family, size: size) != nil {
                return .custom(family, size: size).weight(weight)
            }
            return .system(size: size, weight: weight)
        case .system:  return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .serif:   return .system(size: size, weight: weight, design: .serif)
        case .mono:    return .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
#endif
