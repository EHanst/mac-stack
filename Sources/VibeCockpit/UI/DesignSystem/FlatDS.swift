#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

// MARK: - Color tokens

extension Color {
    // Aliases onto `Palette` (Theme.swift). Names are kept so call sites don't change yet.
    // Primary (indigo-violet accent)
    static let mtPrimary               = Palette.accent
    static let mtOnPrimary             = Palette.onAccent
    static let mtPrimaryContainer      = Palette.accentFill
    static let mtOnPrimaryContainer    = Palette.onAccentFill
    static let mtPrimaryFixed          = Palette.accentFill

    // Secondary (neutral tonal fill)
    static let mtSecondary             = Palette.textSecondary
    static let mtOnSecondary           = Palette.raised
    static let mtSecondaryContainer    = Palette.accentFill
    static let mtOnSecondaryContainer  = Palette.onAccentFill

    // Tertiary (teal info accent for tooling/build)
    static let mtTertiary              = Palette.info
    static let mtOnTertiary            = Palette.onInfo
    static let mtTertiaryContainer     = Palette.infoFill
    static let mtOnTertiaryContainer   = Palette.onInfoFill

    // Error
    static let mtError                 = Palette.danger
    static let mtOnError               = Palette.onDanger
    static let mtErrorContainer        = Palette.dangerFill
    static let mtOnErrorContainer      = Palette.onDangerFill

    // Surface / background
    static let mtSurface               = Palette.raised
    static let mtOnSurface             = Palette.text
    static let mtSurfaceVariant        = Palette.sunken
    static let mtOnSurfaceVariant      = Palette.textSecondary
    static let mtOutline               = Palette.hairline
    static let mtOutlineVariant        = Palette.hairlineSoft

    // Surface containers (tonal steps instead of shadows)
    static let mtSurfaceContainerLowest  = Palette.page
    static let mtSurfaceContainerLow     = Palette.page
    static let mtSurfaceContainer        = Palette.raised
    static let mtSurfaceContainerHigh    = Palette.neutralFill
    static let mtSurfaceContainerHighest = Palette.sunken

    // Inverse
    static let mtInverseSurface    = Palette.text
    static let mtInverseOnSurface  = Palette.raised

    // Status / semantic (for health badges)
    static let mtHealthy     = Palette.success
    static let mtDegraded    = Palette.warning
    static let mtUnavailable = Palette.danger
}

// MARK: - Typography scale

extension Font {
    static var mtDisplayLarge: Font { AppTypography.font(size: 57, weight: .regular) }
    static var mtDisplayMedium: Font { AppTypography.font(size: 45, weight: .regular) }
    static var mtDisplaySmall: Font { AppTypography.font(size: 36, weight: .regular) }
    static var mtHeadlineLarge: Font { AppTypography.font(size: 32, weight: .regular) }
    static var mtHeadlineMedium: Font { AppTypography.font(size: 28, weight: .regular) }
    static var mtHeadlineSmall: Font { AppTypography.font(size: 24, weight: .semibold) }
    static var mtTitleLarge: Font { AppTypography.font(size: 22, weight: .regular) }
    static var mtTitleMedium: Font { AppTypography.font(size: 16, weight: .semibold) }
    static var mtTitleSmall: Font { AppTypography.font(size: 14, weight: .semibold) }
    static var mtBodyLarge: Font { AppTypography.font(size: 16, weight: .regular) }
    static var mtBodyMedium: Font { AppTypography.font(size: 14, weight: .regular) }
    static var mtBodySmall: Font { AppTypography.font(size: 12, weight: .regular) }
    static var mtLabelLarge: Font { AppTypography.font(size: 14, weight: .semibold) }
    static var mtLabelMedium: Font { AppTypography.font(size: 12, weight: .medium) }
    static var mtLabelSmall: Font { AppTypography.font(size: 11, weight: .medium) }
}

// MARK: - Shape & motion

/// Flat 2.0: two radii, no shadows. Depth is a tonal surface step plus a hairline.
enum Radius {
    static let control: CGFloat = 8
    static let card: CGFloat = 12
}

enum Motion {
    /// Short ease for hover/press tone shifts.
    static let quick = Animation.easeOut(duration: 0.13)
}

extension View {
    /// Tone shift on hover. Pair with a button style's own pressed state.
    func flatHover(_ isHovering: Binding<Bool>) -> some View {
        onHover { isHovering.wrappedValue = $0 }
            .animation(Motion.quick, value: isHovering.wrappedValue)
    }
}

// MARK: - Card surface

struct MTCard<Content: View>: View {
    let elevation: Int
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(elevation: Int = 1, padding: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.elevation = elevation
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(Color.mtSurface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Color.mtOutline, lineWidth: 1))
    }
}

// MARK: - Button styles

/// Shared body so every variant gets the same padding, radius, hover tone and press feedback.
private struct FlatButtonBody: View {
    let label: ButtonStyleConfiguration.Label
    let isPressed: Bool
    let fill: Color
    let foreground: Color
    var stroke: Color? = nil
    var horizontal: CGFloat = 16
    var vertical: CGFloat = 8
    @State private var hovering = false

    var body: some View {
        label
            .font(.mtLabelLarge)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(fill)
            .overlay {
                if let stroke {
                    RoundedRectangle(cornerRadius: Radius.control).stroke(stroke, lineWidth: 1)
                }
            }
            .overlay(Color.mtOnSurface.opacity(isPressed ? 0.10 : hovering ? 0.05 : 0)
                .allowsHitTesting(false))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .flatHover($hovering)
    }
}

struct MTFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            fill: isEnabled ? Color.mtPrimary : Color.mtOnSurface.opacity(0.10),
            foreground: isEnabled ? Color.mtOnPrimary : Color.mtOnSurface.opacity(0.38))
    }
}

struct MTTonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            fill: Color.mtSecondaryContainer,
            foreground: Color.mtOnSecondaryContainer)
    }
}

struct MTOutlinedButtonStyle: ButtonStyle {
    var tint: Color = .mtPrimary

    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            fill: Color.clear,
            foreground: tint,
            stroke: Color.mtOutline)
    }
}

struct MTTextButtonStyle: ButtonStyle {
    var tint: Color = .mtPrimary

    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            fill: Color.clear,
            foreground: tint,
            horizontal: 10, vertical: 6)
    }
}

// MARK: - Icon-button

struct MTIconButtonStyle: ButtonStyle {
    var variant: Variant = .standard

    enum Variant { case standard, tonal, filled }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20))
            .frame(width: 40, height: 40)
            .background(background(configuration.isPressed))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    private func background(_ pressed: Bool) -> Color {
        switch variant {
        case .standard: pressed ? Color.mtOnSurface.opacity(0.08) : Color.clear
        case .tonal:    pressed ? Color.mtSecondaryContainer.opacity(0.82) : Color.mtSecondaryContainer
        case .filled:   pressed ? Color.mtPrimary.opacity(0.85) : Color.mtPrimary
        }
    }

    private var foreground: Color {
        switch variant {
        case .standard: Color.mtOnSurfaceVariant
        case .tonal:    Color.mtOnSecondaryContainer
        case .filled:   Color.mtOnPrimary
        }
    }
}

// MARK: - Chip

struct MTFilterChip: View {
    let label: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    init(_ label: String, icon: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.isSelected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: isSelected ? "checkmark" : icon)
                        .font(.system(size: 13))
                }
                Text(label).font(.mtLabelLarge)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.mtSecondaryContainer : Color.clear)
            .overlay(
                Capsule().stroke(isSelected ? Color.clear : Color.mtOutline, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.mtOnSecondaryContainer : Color.mtOnSurfaceVariant)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color-block icon tile and card title

/// A flat block of solid color with a white-ish glyph: the Flat 2.0 signature.
enum MTTint {
    case accent, info, success, warning, danger

    var fill: Color {
        switch self {
        case .accent:  Palette.accent
        case .info:    Palette.info
        case .success: Palette.success
        case .warning: Palette.warning
        case .danger:  Palette.danger
        }
    }
    var glyph: Color {
        switch self {
        case .accent:  Palette.onAccent
        case .info:    Palette.onInfo
        case .success: Palette.onSuccess
        case .warning: Palette.onWarning
        case .danger:  Palette.onDanger
        }
    }
}

struct MTIconTile: View {
    let symbol: String
    var tint: MTTint = .accent
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(tint.glyph)
            .frame(width: size, height: size)
            .background(tint.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// Card heading: a colored icon tile beside a bold title.
struct MTCardTitle: View {
    let title: String
    let icon: String
    var tint: MTTint = .accent

    init(_ title: String, icon: String, tint: MTTint = .accent) {
        self.title = title
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 10) {
            MTIconTile(symbol: icon, tint: tint)
            Text(title)
                .font(.mtTitleSmall)
                .foregroundStyle(Color.mtOnSurface)
        }
    }
}

// MARK: - Section header

struct MTSectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String) { self.title = title }

    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.mtTitleSmall)
                .foregroundStyle(Color.mtOnSurface)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Divider

struct MTDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.mtOutlineVariant)
            .frame(height: 1)
    }
}

// MARK: - Badge

struct MTStatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.mtLabelSmall)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Navigation drawer item

struct MTNavItem: View {
    let icon: String
    let label: String
    let badge: Int
    let isSelected: Bool
    let action: () -> Void

    init(icon: String, label: String, badge: Int = 0, isSelected: Bool, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.badge = badge
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.mtOnPrimary : Color.mtOnSurfaceVariant)
                    .frame(width: 24)
                Text(label)
                    .font(.mtLabelLarge)
                    .foregroundStyle(
                        isSelected ? Color.mtOnPrimary : Color.mtOnSurfaceVariant
                    )
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.mtLabelSmall)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.mtOnPrimary : Color.mtPrimary)
                        .foregroundStyle(isSelected ? Color.mtPrimary : Color.mtOnPrimary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.mtPrimary : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .animation(Motion.quick, value: isSelected)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Progress chip

struct MTProgressChip: View {
    let label: String
    let value: Double   // 0…1; negative = indeterminate

    var body: some View {
        HStack(spacing: 8) {
            if value < 0 {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 16, height: 16)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.mtOutlineVariant, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: value)
                        .stroke(Color.mtPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            }
            Text(label).font(.mtLabelMedium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.mtSurfaceContainerHighest)
        .clipShape(Capsule())
        .foregroundStyle(Color.mtOnSurface)
    }
}
#endif
