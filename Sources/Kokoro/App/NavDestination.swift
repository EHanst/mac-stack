import Foundation

/// The app's top-level places. Lives in the core module (not next to the views) so tests can see it.
public enum NavDestination: Hashable, CaseIterable, Sendable {
    case briefs
    case models
    case prompts
    case settings

    public static let sidebarPrimary: [NavDestination] = [.briefs, .prompts, .models]
    public static let sidebarSecondary: [NavDestination] = [.settings]

    public var label: String {
        switch self {
        case .briefs:    return "Briefs"
        case .models:    return "Models"
        case .prompts:   return "Library"
        case .settings:  return "Settings"
        }
    }

    public var icon: String {
        switch self {
        case .briefs:    return "doc.text.fill"
        case .models:    return "cpu.fill"
        case .prompts:   return "text.book.closed.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}
