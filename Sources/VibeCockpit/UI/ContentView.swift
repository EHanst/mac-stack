#if canImport(AppKit)
import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var showInspector = true
    @State private var contentTab: ContentTab = .diff

    enum ContentTab: Hashable { case diff, preview }

    var body: some View {
        if coordinator.state.onboardingNeeded {
            OnboardingView()
        } else {
            mainLayout
        }
    }

    private var mainLayout: some View {
        NavigationSplitView {
            IntentPane()
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)
        } detail: {
            contentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $showInspector) {
                    SnapshotScrubber()
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                }
        }
        .frame(minWidth: 860, minHeight: 580)
        .toolbar { toolbarItems }
    }

    @ViewBuilder
    private var contentPane: some View {
        switch contentTab {
        case .diff:
            DiffCanvas()
        case .preview:
            PreviewWebView(html: coordinator.state.previewHTML ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Label(services.workspaceName ?? "No Workspace", systemImage: "folder")
                .foregroundStyle(services.workspaceName != nil ? .primary : .secondary)
                .font(.callout)
        }

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $contentTab) {
                Label("Diff", systemImage: "doc.text.magnifyingglass").tag(ContentTab.diff)
                Label("Preview", systemImage: "globe").tag(ContentTab.preview)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .opacity(coordinator.state.previewHTML != nil ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: coordinator.state.previewHTML != nil)
        }

        ToolbarItemGroup(placement: .automatic) {
            ProviderStatusBadge()

            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 18, height: 18)
                .opacity(coordinator.state.isGenerating ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: coordinator.state.isGenerating)

            Button {
                coordinator.send(.clearSession)
            } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }
            .help("Clear and start a new session")
            .disabled(coordinator.state.isGenerating)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Label("Snapshots", systemImage: "clock.arrow.circlepath")
            }
            .help(showInspector ? "Hide snapshot history" : "Show snapshot history")
        }
    }
}

private struct ProviderStatusBadge: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("Model providers — \(statusLabel)")
        .animation(.easeInOut(duration: 0.3), value: dotColor)
    }

    private var dotColor: Color {
        let h = coordinator.state.providerHealth
        guard !h.isEmpty else { return Color.secondary }
        let healthyCount = h.values.filter {
            guard case .healthy = $0 else { return false }
            return true
        }.count
        if healthyCount == h.count { return .green }
        if healthyCount > 0 { return .yellow }
        return .red
    }

    private var statusLabel: String {
        let h = coordinator.state.providerHealth
        guard !h.isEmpty else { return "No providers" }
        let healthyCount = h.values.filter {
            guard case .healthy = $0 else { return false }
            return true
        }.count
        let total = h.count
        if healthyCount == total { return "\(total) provider\(total == 1 ? "" : "s")" }
        if healthyCount > 0 { return "\(healthyCount)/\(total) healthy" }
        return "Unavailable"
    }
}
#endif
