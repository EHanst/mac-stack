#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import AppKit
import SwiftUI

/// The app is the AI endpoint other tools use, so closing the window must not stop it: it keeps
/// running (and the model stays loaded) from the menu bar until the user chooses Quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct VibeCockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var coordinator = AppCoordinator()
    @State private var services = AppServices()
    @State private var loginItem = LoginItemModel()

    var body: some Scene {
        Window("VibeCockpit", id: "main") {
            ContentView()
                .environment(coordinator)
                .environment(services)
                .environment(loginItem)
                .task { await services.startup(coordinator: coordinator) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(coordinator)
                .environment(services)
                .environment(loginItem)
        } label: {
            MenuBarIcon()
                .environment(coordinator)
                // Starts the services at launch even when no window is shown (e.g. login item).
                .task { await services.startup(coordinator: coordinator) }
        }
        .menuBarExtraStyle(.menu)
    }
}
