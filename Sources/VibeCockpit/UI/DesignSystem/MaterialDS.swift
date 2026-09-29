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

// MARK: - Material 3 Typography Scale

extension Font {
    static let mtDisplayLarge   = Font.system(size: 57, weight: .regular, design: .rounded)
    static let mtDisplayMedium  = Font.system(size: 45, weight: .regular, design: .rounded)
    static let mtDisplaySmall   = Font.system(size: 36, weight: .regular, design: .rounded)
    static let mtHeadlineLarge  = Font.system(size: 32, weight: .regular)
    static let mtHeadlineMedium = Font.system(size: 28, weight: .regular)
    static let mtHeadlineSmall  = Font.system(size: 24, weight: .regular)
    static let mtTitleLarge     = Font.system(size: 22, weight: .regular)
    static let mtTitleMedium    = Font.system(size: 16, weight: .medium)
    static let mtTitleSmall     = Font.system(size: 14, weight: .medium)
    static let mtBodyLarge      = Font.system(size: 16, weight: .regular)
    static let mtBodyMedium     = Font.system(size: 14, weight: .regular)
    static let mtBodySmall      = Font.system(size: 12, weight: .regular)
    static let mtLabelLarge     = Font.system(size: 14, weight: .medium)
    static let mtLabelMedium    = Font.system(size: 12, weight: .medium)
    static let mtLabelSmall     = Font.system(size: 11, weight: .medium)
}

// MARK: - Elevation shadows (Material dp levels)

struct MaterialElevation: ViewModifier {
    let level: Int

    private var shadowOpacity: Double {
        switch level {
        case 1: 0.10; case 2: 0.14; case 3: 0.18; case 4: 0.22; case 5: 0.28
        default: 0
        }
    }
    private var radius: CGFloat {
        switch level {
        case 1: 2; case 2: 4; case 3: 8; case 4: 12; case 5: 20
        default: 0
        }
    }
    private var yOffset: CGFloat {
        switch level {
        case 1: 1; case 2: 2; case 3: 4; case 4: 6; case 5: 10
        default: 0
        }
    }

    func body(content: Content) -> some View {
        content
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: radius, x: 0, y: yOffset
            )
    }
}

extension View {
    func mtElevation(_ level: Int) -> some View {
        modifier(MaterialElevation(level: level))
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
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .mtElevation(elevation)
    }
}

// MARK: - Button styles

struct MTFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mtLabelLarge)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                isEnabled
                    ? configuration.isPressed ? Color.mtPrimary.opacity(0.85) : Color.mtPrimary
                    : Color.mtOnSurface.opacity(0.12)
            )
            .foregroundStyle(
                isEnabled ? Color.mtOnPrimary : Color.mtOnSurface.opacity(0.38)
            )
            .clipShape(Capsule())
    }
}

struct MTTonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mtLabelLarge)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                configuration.isPressed
                    ? Color.mtSecondaryContainer.opacity(0.82)
                    : Color.mtSecondaryContainer
            )
            .foregroundStyle(Color.mtOnSecondaryContainer)
            .clipShape(Capsule())
    }
}

struct MTOutlinedButtonStyle: ButtonStyle {
    var tint: Color = .mtPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mtLabelLarge)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .overlay(Capsule().stroke(Color.mtOutline, lineWidth: 1))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

struct MTTextButtonStyle: ButtonStyle {
    var tint: Color = .mtPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mtLabelLarge)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.70 : 1)
    }
}

// MARK: - Icon-button (FAB-mini style)

struct MTIconButtonStyle: ButtonStyle {
    var variant: Variant = .standard

    enum Variant { case standard, tonal, filled }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20))
            .frame(width: 40, height: 40)
            .background(background(configuration.isPressed))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
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
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.mtSecondaryContainer)
                            .frame(width: 56, height: 32)
                    }
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            isSelected ? Color.mtOnSecondaryContainer : Color.mtOnSurfaceVariant
                        )
                        .frame(width: 24)
                }
                Text(label)
                    .font(.mtLabelLarge)
                    .foregroundStyle(
                        isSelected ? Color.mtOnSurface : Color.mtOnSurfaceVariant
                    )
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.mtLabelSmall)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.mtPrimary)
                        .foregroundStyle(Color.mtOnPrimary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
