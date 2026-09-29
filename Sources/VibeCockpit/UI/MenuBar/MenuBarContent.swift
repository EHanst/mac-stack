#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import AppKit
import SwiftUI

/// The menu-bar item's icon; reflects the model's state at a glance.
struct MenuBarIcon: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Image(systemName: MenuBarStatus.make(
            models: coordinator.state.modelInfos,
            isGenerating: coordinator.state.isGenerating,
            onboardingNeeded: coordinator.state.onboardingNeeded,
            indexing: coordinator.state.indexingStatus.isRunning).symbolName)
    }
}

/// The menu: status, open the window, the privacy switch, launch at login, quit.
struct MenuBarContent: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @Environment(LoginItemModel.self) private var loginItem
    @Environment(\.openWindow) private var openWindow

    private var status: MenuBarStatus {
        MenuBarStatus.make(
            models: coordinator.state.modelInfos,
            isGenerating: coordinator.state.isGenerating,
            onboardingNeeded: coordinator.state.onboardingNeeded,
            indexing: coordinator.state.indexingStatus.isRunning)
    }

    var body: some View {
        Text(status.title)
        if let detail = status.detail { Text(detail) }
        if case .running(let port) = services.sharing.status {
            Text("Shared with other apps · port \(port)")
        }
        if !services.approvals.pending.isEmpty {
            Button("\(services.approvals.pending.count) waiting for your OK — Review…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
        }
        Divider()

        Button("Open VibeCockpit") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Picker("Privacy", selection: Binding(
            get: { services.routingPolicy },
            set: { policy in Task { await services.setRoutingPolicy(policy) } })
        ) {
            ForEach(RoutingPolicy.allCases) { Text($0.title).tag($0) }
        }

        Toggle("Launch at login", isOn: Binding(
            get: { loginItem.isOn },
            set: { loginItem.setEnabled($0) }))
            .disabled(!loginItem.isAvailable)
        if let message = loginItem.message { Text(message) }

        Divider()
        Button("Quit VibeCockpit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
#endif
