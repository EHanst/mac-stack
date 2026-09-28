#if canImport(AppKit)
import SwiftUI

struct SnapshotScrubber: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services

    var body: some View {
        List {
            if coordinator.state.snapshotTimeline.isEmpty {
                emptyState
            } else {
                ForEach(coordinator.state.snapshotTimeline) { snap in
                    SnapshotRow(snapshot: snap) {
                        Task { await services.diffAgainstSnapshot(snap, coordinator: coordinator) }
                    } onRestore: {
                        Task { await services.restoreSnapshot(snap, coordinator: coordinator) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Snapshots (\(coordinator.state.snapshotTimeline.count))")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No snapshots yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Snapshots are created automatically\nas you build.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

private struct SnapshotRow: View {
    let snapshot: SnapshotRef
    let onDiff: () -> Void
    let onRestore: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.message)
                .lineLimit(2)
                .font(.subheadline)
            HStack(spacing: 0) {
                Text(snapshot.branchName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isHovered {
                    HStack(spacing: 8) {
                        Button("Diff") { onDiff() }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .foregroundStyle(.secondary)
                        Button("Restore") { onRestore() }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .foregroundStyle(.orange)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    Text(snapshot.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
    }
}
#endif
