#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import AppKit
import SwiftUI

// MARK: - Theme selection

extension AppTheme {
    /// `nil` means "don't pin": SwiftUI then follows the macOS appearance as it changes.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

extension View {
    /// Applies the user's theme choice to this view tree. Apply once, at the window root.
    func appTheme(_ theme: AppTheme) -> some View {
        preferredColorScheme(theme.colorScheme)
    }
}

// MARK: - Adaptive colors

extension Color {
    /// One color defined as a light/dark pair (0xRRGGBB, optional alpha). Resolves against the
    /// appearance of the view it is drawn in, so `preferredColorScheme` and the system both work.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

/// The palette, one light/dark pair per role. Flat 2.0: depth comes from these tonal steps and
/// the hairline, never from shadows. The `mt*` tokens in `FlatDS.swift` alias these.
enum Palette {
    // Surfaces: page < raised. Sunken is for wells inside a raised card.
    static let page         = Color.adaptive(light: 0xECEEF5, dark: 0x111216)
    static let raised       = Color.adaptive(light: 0xFFFFFF, dark: 0x1B1D23)
    static let sunken       = Color.adaptive(light: 0xE9EBF0, dark: 0x0D0E11)
    static let hairline     = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.10)
    static let hairlineSoft = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.06)

    // Text
    static let text          = Color.adaptive(light: 0x16181D, dark: 0xECEEF2)
    static let textSecondary = Color.adaptive(light: 0x596070, dark: 0x9BA2B0)

    // Accent (indigo-violet, a touch lighter in dark for contrast)
    static let accent         = Color.adaptive(light: 0x5B34E8, dark: 0x9A85FF)
    static let onAccent       = Color.adaptive(light: 0xFFFFFF, dark: 0x160F3A)
    static let accentFill     = Color.adaptive(light: 0xE7E2FB, dark: 0x2B2555)
    static let onAccentFill   = Color.adaptive(light: 0x241A5E, dark: 0xDDD6FF)

    // Neutral tonal fill (secondary buttons, selected rows)
    static let neutralFill    = Color.adaptive(light: 0xE6E8EE, dark: 0x2A2D36)
    static let onNeutralFill  = Color.adaptive(light: 0x1F232B, dark: 0xE2E5EB)

    // Info (teal)
    static let info           = Color.adaptive(light: 0x1B6E7B, dark: 0x5CC4D4)
    static let onInfo         = Color.adaptive(light: 0xFFFFFF, dark: 0x06282D)
    static let infoFill       = Color.adaptive(light: 0xD6F0F4, dark: 0x12353C)
    static let onInfoFill     = Color.adaptive(light: 0x06333A, dark: 0xC9F1F7)

    // Status
    static let success        = Color.adaptive(light: 0x1B7F3A, dark: 0x5CCB7C)
    static let successFill    = Color.adaptive(light: 0xDDF3E3, dark: 0x163523)
    static let onSuccessFill  = Color.adaptive(light: 0x0D4A22, dark: 0xC8F0D3)
    static let onSuccess      = Color.adaptive(light: 0xFFFFFF, dark: 0x07240F)
    static let warning        = Color.adaptive(light: 0x9A5B00, dark: 0xF0B44C)
    static let onWarning      = Color.adaptive(light: 0xFFFFFF, dark: 0x2D1D00)
    static let warningFill    = Color.adaptive(light: 0xFBEBCF, dark: 0x3A2A0E)
    static let onWarningFill  = Color.adaptive(light: 0x5C3500, dark: 0xF8DFB0)
    static let danger         = Color.adaptive(light: 0xB3261E, dark: 0xF28B82)
    static let onDanger       = Color.adaptive(light: 0xFFFFFF, dark: 0x3B0906)
    static let dangerFill     = Color.adaptive(light: 0xFBE4E2, dark: 0x4A1D1A)
    static let onDangerFill   = Color.adaptive(light: 0x410E0B, dark: 0xFFDAD6)
}
#endif
