import SwiftUI
import VibeCockpitCore

@main
struct VibeCockpitApp: App {
    @State private var coordinator = AppCoordinator()
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .environment(services)
                .task {
                    await services.startup(coordinator: coordinator)
                    // Structured teardown: task is cancelled when the window closes
                    try? await Task.sleep(for: .seconds(86400 * 365))
                }
                .onDisappear {
                    Task { await services.stopMCPService() }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
