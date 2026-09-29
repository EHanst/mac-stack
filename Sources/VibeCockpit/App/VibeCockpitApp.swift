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

/// Set once at launch. macOS marks a login-item launch on the "open application" Apple event.
enum AppLaunch {
    static let startsHidden: Bool = {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let asLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        return LaunchMode.startsHidden(arguments: CommandLine.arguments, launchedAsLoginItem: asLoginItem)
    }()
}

extension AppLaunch {
    /// SwiftUI opens the main window at launch and offers no supported way to skip that (the
    /// `.suppressed` launch behaviour did not stop it here), so close it as soon as it exists.
    /// "Open VibeCockpit" in the menu bar brings it back.
    @MainActor static func closeMainWindowWhenItAppears() async {
        for _ in 0..<60 {
            if let window = NSApp.windows.first(where: { $0.title == "VibeCockpit" }) {
                window.close()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The menu-bar icon. Also wires "an app is asking for approval" to opening the window, which may
/// not exist yet when the app started hidden at login.
struct MenuBarLabel: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @Environment(UpdatesModel.self) private var updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarIcon()
            // Starts the services at launch even when no window is shown (e.g. login item).
            .task {
                services.approvals.onNeedsAttention = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                if AppLaunch.startsHidden { await AppLaunch.closeMainWindowWhenItAppears() }
                await services.startup(coordinator: coordinator)
                // Opt-in daily update check; does nothing unless the user turned it on.
                while !Task.isCancelled {
                    await updates.checkIfDue(policy: services.routingPolicy)
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
    }
}

@main
struct VibeCockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var coordinator = AppCoordinator()
    @State private var services = AppServices()
    @State private var loginItem = LoginItemModel()
    @State private var updates = UpdatesModel()
    @AppStorage(AppTheme.storageKey) private var themeChoice = AppTheme.default.rawValue

    var body: some Scene {
        Window("VibeCockpit", id: "main") {
            ContentView()
                .appTheme(AppTheme(stored: themeChoice))
                .environment(coordinator)
                .environment(services)
                .environment(loginItem)
                .environment(updates)
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
                .environment(updates)
        } label: {
            MenuBarLabel()
                .environment(coordinator)
                .environment(services)
                .environment(updates)
        }
        .menuBarExtraStyle(.menu)
    }
}
