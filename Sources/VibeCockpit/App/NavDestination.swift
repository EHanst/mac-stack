import Foundation

/// The app's top-level places. Lives in the core module (not next to the views) so tests can see it.
public enum NavDestination: Hashable, CaseIterable, Sendable {
    case briefs
    case chat
    case diff
    case models
    case prompts
    case tools
    case snapshots
    case settings

    /// The IDE panes (Changes, Snapshots) stay defined but are not offered; the sidecar is prompt-first.
    public static let sidebarPrimary: [NavDestination] = [.briefs, .prompts, .models]
    public static let sidebarSecondary: [NavDestination] = [.chat, .tools, .settings]

    public var label: String {
        switch self {
        case .briefs:    return "Briefs"
        case .chat:      return "Quick ask"
        case .diff:      return "Changes"
        case .models:    return "Models"
        case .prompts:   return "Library"
        case .tools:     return "MCP Tools"
        case .snapshots: return "Snapshots"
        case .settings:  return "Settings"
        }
    }

    public var icon: String {
        switch self {
        case .briefs:    return "doc.text.fill"
        case .chat:      return "bubble.left.and.bubble.right.fill"
        case .diff:      return "arrow.left.arrow.right.circle.fill"
        case .models:    return "cpu.fill"
        case .prompts:   return "text.book.closed.fill"
        case .tools:     return "wrench.and.screwdriver.fill"
        case .snapshots: return "camera.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}
