#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
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

    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        font(current, size: size, weight: weight)
    }

    static func font(_ choice: AppFont, size: CGFloat, weight: Font.Weight) -> Font {
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
