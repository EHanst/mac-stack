import SwiftUI

@main
struct VibeCockpitApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
