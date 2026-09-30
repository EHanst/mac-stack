#if SWIFT_PACKAGE
import StackCore
#endif
import Foundation

/// What the menu-bar icon and its first menu line say. Pure, so every state is unit-tested.
public struct MenuBarStatus: Equatable, Sendable {

    public enum Level: Equatable, Sendable {
        case ready       // a chat model is loaded and idle
        case busy        // generating
        case warming     // a local model exists but isn't loaded yet
        case attention   // needs the user: setup, or nothing usable
    }

    public let level: Level
    public let title: String
    public let detail: String?
    public let symbolName: String

    public static func make(
        models: [ModelInfo], isGenerating: Bool, onboardingNeeded: Bool, indexing: Bool = false
    ) -> MenuBarStatus {
        if onboardingNeeded {
            return MenuBarStatus(level: .attention, title: "Set up \(AppBrand.name)",
                                 detail: "Open the app to choose a model.", symbolName: "exclamationmark.circle")
        }
        let chat = models.filter { $0.capabilities.contains(.textGeneration) }
        if isGenerating {
            return MenuBarStatus(level: .busy, title: "Working…",
                                 detail: chat.first(where: { $0.health == .healthy })?.displayName,
                                 symbolName: "bolt.circle.fill")
        }
        if let ready = chat.first(where: { $0.health == .healthy }) {
            let where_ = ready.kind == .local ? "on this Mac" : "in the cloud"
            return MenuBarStatus(level: .ready, title: "Ready — \(ready.displayName)",
                                 detail: indexing ? "Indexing your workspace…" : "Running \(where_)",
                                 symbolName: "bolt.circle")
        }
        if let loading = chat.first(where: { if case .degraded = $0.health { return true } else { return false } }) {
            return MenuBarStatus(level: .warming, title: "Loading \(loading.displayName)…",
                                 detail: "First load takes a few seconds.", symbolName: "bolt.circle")
        }
        if let broken = chat.first {
            var why = "Not available"
            if case .unavailable(let reason) = broken.health { why = reason }
            return MenuBarStatus(level: .attention, title: "\(broken.displayName) unavailable",
                                 detail: why, symbolName: "exclamationmark.circle")
        }
        return MenuBarStatus(level: .attention, title: "No model", detail: "Open the app to add one.",
                             symbolName: "exclamationmark.circle")
    }
}
