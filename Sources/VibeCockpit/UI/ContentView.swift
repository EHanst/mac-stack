#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

// MARK: - Navigation destinations

enum NavDestination: Hashable, CaseIterable {
    case chat
    case diff
    case models
    case tools
    case snapshots
    case settings

    var label: String {
        switch self {
        case .chat:      return "Chat"
        case .diff:      return "Changes"
        case .models:    return "Models"
        case .tools:     return "MCP Tools"
        case .snapshots: return "Snapshots"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat:      return "bubble.left.and.bubble.right.fill"
        case .diff:      return "arrow.left.arrow.right.circle.fill"
        case .models:    return "cpu.fill"
        case .tools:     return "wrench.and.screwdriver.fill"
        case .snapshots: return "camera.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}

// MARK: - Root content view

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services

    var body: some View {
        Group {
            if coordinator.state.onboardingNeeded {
                OnboardingView()
            } else {
                MainLayout()
            }
        }
        // Other apps asking to change files or run commands; answered before anything else.
        .sheet(item: Binding(
            get: { services.approvals.pending.first },
            set: { _ in })
        ) { request in
            ApprovalSheet(request: request, waitingAfterThis: services.approvals.pending.count - 1) {
                services.approvals.resolve(request.id, $0)
            }
        }
    }
}

// MARK: - Main layout

struct MainLayout: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedDestination: NavDestination = .chat
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            contentPanel
                .navigationSplitViewColumnWidth(min: 360, ideal: 440, max: 640)
        } detail: {
            detailPanel
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarBrand
            MTDivider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(primaryItems, id: \.self) { dest in
                        MTNavItem(
                            icon: dest.icon,
                            label: dest.label,
                            badge: badge(for: dest),
                            isSelected: selectedDestination == dest
                        ) {
                            selectedDestination = dest
                        }
                    }
                    Divider()
                        .background(Color.mtOutlineVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    ForEach(secondaryItems, id: \.self) { dest in
                        MTNavItem(
                            icon: dest.icon,
                            label: dest.label,
                            badge: badge(for: dest),
                            isSelected: selectedDestination == dest
                        ) {
                            selectedDestination = dest
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Spacer()
            MTDivider()
            sidebarFooter
        }
        .background(Color.mtSurfaceContainerLow)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    private var primaryItems: [NavDestination] { [.chat, .diff, .models] }
    private var secondaryItems: [NavDestination] { [.tools, .snapshots, .settings] }

    private func badge(for dest: NavDestination) -> Int {
        switch dest {
        case .diff:
            let hunks = coordinator.state.currentDiff?.hunks.count ?? 0
            return hunks > 0 ? hunks : 0
        case .snapshots:
            return coordinator.state.snapshotTimeline.count
        case .models:
            let unhealthy = coordinator.state.modelInfos.filter {
                if case .healthy = $0.health { return false } else { return true }
            }.count
            return unhealthy
        default: return 0
        }
    }

    // MARK: Brand header

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.mtPrimary)
                    .frame(width: 36, height: 36)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mtOnPrimary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("VibeCockpit")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                Text("AI Coding IDE")
                    .font(.mtLabelSmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Sidebar footer

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            providerDot
            generatingIndicator
            Spacer()
            if coordinator.state.indexingStatus.isRunning {
                MTProgressChip(
                    label: "Indexing",
                    value: coordinator.state.indexingStatus.progress
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var providerDot: some View {
        let anyHealthy = coordinator.state.providerHealth.values.contains(.healthy)
        Circle()
            .fill(anyHealthy ? Color.mtHealthy : Color.mtUnavailable)
            .frame(width: 8, height: 8)
        Text(anyHealthy ? "Model ready" : "No model")
            .font(.mtLabelSmall)
            .foregroundStyle(Color.mtOnSurfaceVariant)
    }

    @ViewBuilder
    private var generatingIndicator: some View {
        if coordinator.state.isGenerating {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: Content panel (center)

    @ViewBuilder
    private var contentPanel: some View {
        switch selectedDestination {
        case .chat:      IntentPane()
        case .diff:      DiffCanvas()
        case .models:    ModelManagerView()
        case .tools:     MCPToolsView()
        case .snapshots: SnapshotScrubber()
        case .settings:  SettingsView()
        }
    }

    // MARK: Detail panel (right — always shows diff)

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if selectedDestination == .diff {
                // Diff is already the content panel; show preview or placeholder
                previewOrEmpty
            } else if coordinator.state.currentDiff != nil {
                DiffCanvas()
            } else {
                previewOrEmpty
            }
        }
    }

    @ViewBuilder
    private var previewOrEmpty: some View {
        if let html = coordinator.state.previewHTML, !html.isEmpty {
            PreviewWebView(html: html)
        } else {
            detailPlaceholder
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.35))
            Text("Preview")
                .font(.mtTitleMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.5))
            Text("Web previews will appear here when the agent generates HTML output.")
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mtSurfaceContainerLowest)
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @Environment(LoginItemModel.self) private var loginItem
    @State private var workspacePath: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                generationSection
                startupSection
                CloudUsageCard()
                SharingCard()
                ConnectCard()
                indexingSection
                aboutSection
            }
            .padding(24)
        }
        .background(Color.mtSurfaceContainerLowest)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.mtHeadlineSmall)
                .foregroundStyle(Color.mtOnSurface)
            Text("Configure VibeCockpit's inference, indexing and workspace behaviour.")
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private var generationSection: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Inference", systemImage: "sparkles")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                providerHealthRows
            }
        }
    }

    private var startupSection: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Privacy & startup", systemImage: "lock.shield")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where your work is processed")
                        .font(.mtLabelLarge)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                    Picker("Privacy", selection: Binding(
                        get: { services.routingPolicy },
                        set: { policy in Task { await services.setRoutingPolicy(policy) } })
                    ) {
                        ForEach(RoutingPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(services.routingPolicy.summary)
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MTDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch VibeCockpit at login", isOn: Binding(
                        get: { loginItem.isOn },
                        set: { loginItem.setEnabled($0) }))
                        .disabled(!loginItem.isAvailable)
                    Text("VibeCockpit keeps running in the menu bar when you close its window, so other apps can keep using your local model.")
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = loginItem.message {
                        Text(message).font(.mtBodySmall).foregroundStyle(Color.mtDegraded)
                    }
                }
            }
        }
    }

    private var providerHealthRows: some View {
        ForEach(
            coordinator.state.modelInfos.sorted { $0.id < $1.id },
            id: \.id
        ) { model in
            HStack {
                Image(systemName: model.kind == .local ? "internaldrive" : "cloud")
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.mtBodyMedium)
                        .foregroundStyle(Color.mtOnSurface)
                    Text(model.id)
                        .font(.mtLabelSmall)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                }
                Spacer()
                healthBadge(model.health)
            }
        }
    }

    @ViewBuilder
    private func healthBadge(_ health: ProviderHealth) -> some View {
        switch health {
        case .healthy:
            MTStatusBadge(label: "Ready", color: .mtHealthy)
        case .degraded(let m):
            MTStatusBadge(label: "Degraded", color: .mtDegraded).help(m)
        case .unavailable(let m):
            MTStatusBadge(label: "Unavailable", color: .mtUnavailable).help(m)
        }
    }

    private var indexingSection: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Indexing", systemImage: "arrow.clockwise.circle")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.mtLabelLarge)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                        Text(coordinator.state.indexingStatus.isRunning
                             ? "Indexing in progress…"
                             : "Idle")
                            .font(.mtBodyMedium)
                            .foregroundStyle(Color.mtOnSurface)
                    }
                    Spacer()
                    if coordinator.state.indexingStatus.isRunning {
                        MTProgressChip(
                            label: "\(coordinator.state.indexingStatus.filesIndexed) / \(coordinator.state.indexingStatus.totalFiles)",
                            value: coordinator.state.indexingStatus.progress
                        )
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("About", systemImage: "info.circle")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                infoRow("Platform", "macOS 26+  ·  Apple Silicon")
                infoRow("Inference", "MLX Swift (in-process)")
                infoRow("Vector DB", "SQLite-vec + FTS5")
                infoRow("Version Control", "libgit2 (C binding)")
                infoRow("MCP", "modelcontextprotocol/swift-sdk")
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.mtLabelLarge)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurface)
            Spacer()
        }
    }
}
#endif
