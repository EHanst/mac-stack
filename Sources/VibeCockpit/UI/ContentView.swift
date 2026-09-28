#if canImport(AppKit)
import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        if coordinator.state.onboardingNeeded {
            OnboardingView()
        } else {
            mainLayout
        }
    }

    private var mainLayout: some View {
        HSplitView {
            IntentPane()
                .frame(minWidth: 300, idealWidth: 380)
            DiffCanvas()
                .frame(minWidth: 400)
            if coordinator.state.previewHTML != nil {
                PreviewWebView(html: coordinator.state.previewHTML ?? "")
                    .frame(minWidth: 300, idealWidth: 380)
            }
            SnapshotScrubber()
                .frame(minWidth: 200, idealWidth: 240)
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}
#endif
