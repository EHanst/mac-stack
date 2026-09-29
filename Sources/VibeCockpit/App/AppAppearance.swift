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
