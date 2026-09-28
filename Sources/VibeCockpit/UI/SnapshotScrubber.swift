#if canImport(AppKit)
import SwiftUI

struct SnapshotScrubber: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            snapshotList
        }
    }

    private var header: some View {
        Text("Snapshots")
            .font(.headline)
            .padding(12)
    }

    private var snapshotList: some View {
        Group {
            if coordinator.state.snapshotTimeline.isEmpty {
                Text("No snapshots yet")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(coordinator.state.snapshotTimeline) { snap in
                    SnapshotRow(snapshot: snap) {
                        Task { await services.diffAgainstSnapshot(snap, coordinator: coordinator) }
                    } onRestore: {
                        Task { await services.restoreSnapshot(snap, coordinator: coordinator) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: SnapshotRef
    let onDiff: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.message)
                .lineLimit(2)
            HStack {
                Text(snapshot.branchName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button("Diff") { onDiff() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("Restore") { onRestore() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
