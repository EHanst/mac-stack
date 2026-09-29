#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

// MARK: - MCP Tools Panel

struct MCPToolsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services

    private static let toolMeta: [String: (icon: String, description: String, category: String)] = [
        "search_code":       ("magnifyingglass.circle.fill", "Hybrid semantic + BM25 code search over indexed Swift declarations.", "Retrieval"),
        "index_workspace":   ("arrow.clockwise.circle.fill", "Re-index all Swift files in a workspace directory for RAG retrieval.", "Indexing"),
        "read_file":         ("doc.text.fill", "Read file contents within the workspace, optionally line-sliced.", "Files"),
        "write_file":        ("square.and.pencil", "Write or overwrite a workspace file.", "Files"),
        "run_build":         ("hammer.fill", "Execute a sandboxed build command (seatbelted, no network).", "Build"),
        "snapshot_create":   ("camera.fill", "Create a git snapshot of the current workspace state via libgit2.", "Git"),
        "snapshot_diff":     ("arrow.left.arrow.right", "List files changed since a previous snapshot OID.", "Git"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            MTDivider()
            if coordinator.state.mcpToolNames.isEmpty {
                emptyState
            } else {
                toolList
            }
        }
        .background(Color.mtSurfaceContainerLowest)
        .task {
            await services.refreshMCPTools(coordinator: coordinator)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Tools")
                    .font(.mtTitleLarge)
                    .foregroundStyle(Color.mtOnSurface)
                Text("In-process tools exposed via the MCP server socket")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
            socketStatusBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.mtSurface)
    }

    private var socketStatusBadge: some View {
        let running = !coordinator.state.mcpToolNames.isEmpty
        return MTStatusBadge(
            label: running ? "Server Running" : "Not Running",
            color: running ? .mtHealthy : .mtUnavailable
        )
    }

    // MARK: Tool list

    private var toolList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let categories = groupedByCategory()
                ForEach(categories, id: \.0) { (category, tools) in
                    Section {
                        ForEach(tools, id: \.self) { toolName in
                            toolRow(toolName)
                            if toolName != tools.last {
                                MTDivider().padding(.leading, 64)
                            }
                        }
                    } header: {
                        MTSectionHeader(category)
                            .background(Color.mtSurfaceContainerHighest)
                    }
                }
            }
            .background(Color.mtSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
    }

    private func toolRow(_ name: String) -> some View {
        let meta = Self.toolMeta[name]
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconBackground(for: meta?.category))
                    .frame(width: 40, height: 40)
                Image(systemName: meta?.icon ?? "wrench.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(iconForeground(for: meta?.category))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                Text(meta?.description ?? "")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.mtSurface)
        .contentShape(Rectangle())
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(Color.mtPrimary.opacity(0.5))
            Text("MCP Server Not Running")
                .font(.mtHeadlineSmall)
                .foregroundStyle(Color.mtOnSurface)
            Text("Open a workspace to start the embedded MCP server. Tools become available once the indexing pipeline and git manager are initialized.")
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Grouping

    private func groupedByCategory() -> [(String, [String])] {
        var groups: [String: [String]] = [:]
        for name in coordinator.state.mcpToolNames {
            let cat = Self.toolMeta[name]?.category ?? "Other"
            groups[cat, default: []].append(name)
        }
        let order = ["Retrieval", "Indexing", "Files", "Build", "Git", "Other"]
        return order.compactMap { cat in
            guard let tools = groups[cat], !tools.isEmpty else { return nil }
            return (cat, tools)
        }
    }

    private func iconBackground(for category: String?) -> Color {
        switch category {
        case "Retrieval": return Color.mtPrimaryContainer
        case "Indexing":  return Color.mtSecondaryContainer
        case "Files":     return Color.mtTertiaryContainer
        case "Build":     return Palette.warningFill
        case "Git":       return Palette.successFill
        default:          return Color.mtSurfaceVariant
        }
    }

    private func iconForeground(for category: String?) -> Color {
        switch category {
        case "Retrieval": return Color.mtOnPrimaryContainer
        case "Indexing":  return Color.mtOnSecondaryContainer
        case "Files":     return Color.mtOnTertiaryContainer
        case "Build":     return Palette.onWarningFill
        case "Git":       return Palette.onSuccessFill
        default:          return Color.mtOnSurfaceVariant
        }
    }
}
#endif
