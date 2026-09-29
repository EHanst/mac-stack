import Foundation

/// Which look the window uses. `system` follows macOS live; the other two pin it.
/// Pure, so the choice and its stored form are unit-tested.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let storageKey = "appTheme"
    public static let `default`: AppTheme = .system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// Decodes a stored value; anything unknown (or missing) falls back to following the system.
    public init(stored: String?) {
        self = stored.flatMap(AppTheme.init(rawValue:)) ?? .default
    }
}

/// The interface/reply typeface. Every option ships with macOS, so nothing is bundled.
/// Code, diffs and the syntax highlighter stay monospaced regardless.
public enum AppFont: String, CaseIterable, Identifiable, Sendable {
    case osaka, skia, system, rounded, serif, mono

    public static let storageKey = "appFont"
    public static let `default`: AppFont = .osaka

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .osaka:   "Osaka"
        case .skia:    "Skia"
        case .system:  "System (SF Pro)"
        case .rounded: "Rounded (SF Rounded)"
        case .serif:   "Serif (New York)"
        case .mono:    "Mono (SF Mono)"
        }
    }

    /// Installed family name for the named faces; `nil` for the system design variants.
    public var familyName: String? {
        switch self {
        case .osaka: "Osaka"
        case .skia:  "Skia"
        default:     nil
        }
    }

    /// Decodes a stored value; anything unknown (or missing) falls back to the default.
    public init(stored: String?) {
        self = stored.flatMap(AppFont.init(rawValue:)) ?? .default
    }
}
