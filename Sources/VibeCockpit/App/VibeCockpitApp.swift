import SwiftUI

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
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
