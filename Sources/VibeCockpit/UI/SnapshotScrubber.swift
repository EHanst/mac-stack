#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

struct SnapshotScrubber: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(spacing: 0) {
            snapshotHeader
            MTDivider()
            if coordinator.state.snapshotTimeline.isEmpty {
                emptyState
            } else {
                snapshotList
            }
        }
        .background(Color.mtSurface)
    }

    // MARK: Header

    private var snapshotHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.mtOnSurfaceVariant)
            VStack(alignment: .leading, spacing: 1) {
                Text("Snapshots")
                    .font(.mtTitleMedium)
                    .foregroundStyle(Color.mtOnSurface)
                Text("\(coordinator.state.snapshotTimeline.count) saved")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: List

    private var snapshotList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(coordinator.state.snapshotTimeline.enumerated()), id: \.element.id) { idx, snap in
                    SnapshotTimelineRow(
                        snapshot: snap,
                        isFirst: idx == 0,
                        isLast: idx == coordinator.state.snapshotTimeline.count - 1
                    ) {
                        Task { await services.diffAgainstSnapshot(snap, coordinator: coordinator) }
                    } onRestore: {
                        Task { await services.restoreSnapshot(snap, coordinator: coordinator) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.5))
            Text("No snapshots yet")
                .font(.mtTitleSmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)
            Text("The agent creates snapshots automatically after each successful change.")
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Snapshot timeline row

private struct SnapshotTimelineRow: View {
    let snapshot: SnapshotRef
    let isFirst: Bool
    let isLast: Bool
    let onDiff: () -> Void
    let onRestore: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline connector
            VStack(spacing: 0) {
                if !isFirst {
                    Rectangle()
                        .fill(Color.mtOutlineVariant)
                        .frame(width: 2, height: 10)
                } else {
                    Spacer().frame(height: 10)
                }
                ZStack {
                    Circle()
                        .fill(isFirst ? Color.mtPrimary : Color.mtSurfaceContainerHighest)
                        .frame(width: 12, height: 12)
                    if isFirst {
                        Circle()
                            .fill(Color.mtOnPrimary)
                            .frame(width: 5, height: 5)
                    }
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.mtOutlineVariant)
                        .frame(width: 2)
                }
            }
            .frame(width: 12)
            .padding(.top, 10)

            // Card
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.message)
                        .font(isFirst ? .mtTitleSmall : .mtBodyMedium)
                        .foregroundStyle(Color.mtOnSurface)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Label(snapshot.branchName, systemImage: "arrow.triangle.branch")
                            .font(.mtLabelSmall)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                        Text("·")
                            .foregroundStyle(Color.mtOutlineVariant)
                        Text(snapshot.createdAt, style: .relative)
                            .font(.mtLabelSmall)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                    }

                    Text(snapshot.oid.prefix(8))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.6))
                }

                if isHovered {
                    HStack(spacing: 6) {
                        Button("View Diff") { onDiff() }
                            .buttonStyle(MTTonalButtonStyle())
                            .controlSize(.small)
                        Button("Restore") { onRestore() }
                            .buttonStyle(MTOutlinedButtonStyle(tint: .mtError))
                            .controlSize(.small)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isFirst ? Color.mtPrimaryFixed.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
#endif
