#if canImport(AppKit)
import SwiftUI

struct DiffCanvas: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            if let diff = coordinator.state.currentDiff {
                diffView(diff)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No changes yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffView(_ diff: UnifiedDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    HunkView(hunk: hunk)
                }
            }
            .padding()
        }
    }
}

private struct HunkView: View {
    let hunk: UnifiedDiff.Hunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.filePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(line: line)
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.DiffLine

    var background: Color {
        switch line.origin {
        case .added:   return Color.green.opacity(0.15)
        case .deleted: return Color.red.opacity(0.15)
        case .context: return Color.clear
        }
    }

    var body: some View {
        Text(line.content)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
#endif
