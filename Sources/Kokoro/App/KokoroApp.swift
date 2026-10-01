#if SWIFT_PACKAGE
import KokoroCore
#endif
import AppKit
import SwiftUI

/// The app is the AI endpoint other tools use, so closing the window or pressing Cmd-Q must not
/// stop it: it keeps running (and the model stays loaded) from the menu bar, with no Dock icon,
/// until the user chooses Quit in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu-bar Quit item, the one in-app way to stop the app.
    static var quitRequested = false
    /// Set at launch: writes any brief edit still waiting on its autosave delay before the app exits.
    static var flushBeforeQuit: (@MainActor () async -> Void)?
    private static let mainWindowTitle = AppBrand.name
    /// `keyQuitReason` ('why?') on the quit Apple event; says whether the system is logging out etc.
    private static let quitReasonKeyword: AEKeyword = 0x7768_793F

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let code = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: Self.quitReasonKeyword)?.enumCodeValue
        switch QuitPolicy.decide(explicitQuit: Self.quitRequested, reason: QuitReason(appleEventCode: code)) {
        case .terminate:
            guard let flush = Self.flushBeforeQuit else { return .terminateNow }
            Task { @MainActor in
                await flush()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .hideAndKeepRunning:
            for window in NSApp.windows where window.title == Self.mainWindowTitle { window.close() }
            return .terminateCancel
        }
    }

    /// Dock icon (and Cmd-Tab entry) only while the main window is open; otherwise menu bar only.
    func applicationDidFinishLaunching(_ notification: Notification) {
        for name in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            // Re-check after the event settles: a window that is closing is still visible inside willClose.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Self.syncActivationPolicy() }
            }
        }
    }

    private static func syncActivationPolicy() {
        let windowOpen = NSApp.windows.contains { $0.title == mainWindowTitle && $0.isVisible }
        let wanted: NSApplication.ActivationPolicy = windowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if windowOpen { NSApp.activate(ignoringOtherApps: true) }
    }
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
    /// "Open Kokoro" in the menu bar brings it back.
    @MainActor static func closeMainWindowWhenItAppears() async {
        for _ in 0..<60 {
            if let window = NSApp.windows.first(where: { $0.title == AppBrand.name }) {
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
                AppDelegate.flushBeforeQuit = { [briefs = services.briefs] in await briefs.flushNow() }
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
struct KokoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var coordinator = AppCoordinator()
    @State private var services = AppServices()
    @State private var loginItem = LoginItemModel()
    @State private var updates = UpdatesModel()
    @AppStorage(AppTheme.storageKey) private var themeChoice = AppTheme.default.rawValue

    var body: some Scene {
        Window(AppBrand.name, id: "main") {
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
