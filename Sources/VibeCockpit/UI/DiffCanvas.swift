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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No changes")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Describe what you want to build to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffView(_ diff: UnifiedDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    HunkView(hunk: hunk)
                }
            }
            .padding(16)
        }
    }
}

private struct HunkView: View {
    let hunk: UnifiedDiff.Hunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader
            Divider()
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(line: line)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var fileHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(hunk.filePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(hunk.lines.filter { $0.origin == .added }.count)  -\(hunk.lines.filter { $0.origin == .deleted }.count)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(prefix)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 20, alignment: .center)
                .padding(.vertical, 1)
            Text(line.content)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
        }
        .background(background)
    }

    private var prefix: String {
        switch line.origin {
        case .added:   "+"
        case .deleted: "-"
        case .context: " "
        }
    }

    private var background: Color {
        switch line.origin {
        case .added:   Color(nsColor: .systemGreen).opacity(0.12)
        case .deleted: Color(nsColor: .systemRed).opacity(0.12)
        case .context: .clear
        }
    }

    private var prefixColor: Color {
        switch line.origin {
        case .added:   Color(nsColor: .systemGreen)
        case .deleted: Color(nsColor: .systemRed)
        case .context: .tertiary
        }
    }

    private var textColor: Color {
        switch line.origin {
        case .added, .deleted: .primary
        case .context:         .secondary
        }
    }
}
#endif
