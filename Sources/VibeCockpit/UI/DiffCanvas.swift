#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

struct DiffCanvas: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            MTDivider()
            Group {
                if let diff = coordinator.state.currentDiff {
                    if diff.isEmpty {
                        noDeltaState
                    } else {
                        diffScrollView(diff)
                    }
                } else {
                    emptyState
                }
            }
        }
        .background(Color.mtSurface)
    }

    // MARK: Header

    private var diffHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(Color.mtOnSurfaceVariant)
            Text("Changes")
                .font(.mtTitleMedium)
                .foregroundStyle(Color.mtOnSurface)
            if let diff = coordinator.state.currentDiff, !diff.isEmpty {
                Spacer()
                HStack(spacing: 8) {
                    Text("\(diff.hunks.count) file(s)")
                        .font(.mtLabelMedium)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                    let stats = diffStats(diff)
                    if stats.added > 0 {
                        Text("+\(stats.added)")
                            .font(.mtLabelMedium)
                            .foregroundStyle(Color.mtHealthy)
                    }
                    if stats.deleted > 0 {
                        Text("-\(stats.deleted)")
                            .font(.mtLabelMedium)
                            .foregroundStyle(Color.mtError)
                    }
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Diff scroll view

    private func diffScrollView(_ diff: UnifiedDiff) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    MaterialHunkCard(hunk: hunk)
                }
            }
            .padding(12)
        }
    }

    // MARK: Empty / no-delta states

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.mtSurfaceContainerHighest)
                    .frame(width: 72, height: 72)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Text("No changes yet")
                .font(.mtTitleMedium)
                .foregroundStyle(Color.mtOnSurface)
            Text("Describe a change in the chat pane and the diff will appear here.")
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mtSurfaceContainerLowest)
    }

    private var noDeltaState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.mtHealthy)
            Text("No differences found")
                .font(.mtTitleMedium)
                .foregroundStyle(Color.mtOnSurface)
            Text("The selected snapshot matches the current workspace state.")
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mtSurfaceContainerLowest)
    }

    // MARK: Stats

    private func diffStats(_ diff: UnifiedDiff) -> (added: Int, deleted: Int) {
        var added = 0
        var deleted = 0
        for hunk in diff.hunks {
            for line in hunk.lines {
                switch line.origin {
                case .added:   added += 1
                case .deleted: deleted += 1
                case .context: break
                }
            }
        }
        return (added, deleted)
    }
}

// MARK: - Hunk card (Material elevation 1)

private struct MaterialHunkCard: View {
    let hunk: UnifiedDiff.Hunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader
            Divider().background(Color.mtOutlineVariant)
            codeLines
        }
        .background(Color.mtSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var fileHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.system(size: 12))
                .foregroundStyle(Color.mtOnSurfaceVariant)
            Text(hunk.filePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.mtOnSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(addedCount)+  \(deletedCount)−")
                .font(.mtLabelSmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.mtSurfaceContainerHighest)
    }

    private var codeLines: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(line: line)
            }
        }
    }

    private var fileIcon: String {
        let ext = URL(fileURLWithPath: hunk.filePath).pathExtension
        switch ext {
        case "swift":   return "swift"
        case "json":    return "curlybraces"
        case "md":      return "doc.text"
        default:        return "doc"
        }
    }

    private var addedCount: Int {
        hunk.lines.filter { $0.origin == .added }.count
    }
    private var deletedCount: Int {
        hunk.lines.filter { $0.origin == .deleted }.count
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.DiffLine

    var body: some View {
        HStack(spacing: 0) {
            // Gutter
            Text(gutterSymbol)
                .font(.system(size: AppTypography.scaled(11), design: .monospaced))
                .foregroundStyle(gutterColor)
                .frame(width: 20, alignment: .center)
                .background(gutterBackground)
            // Line content
            Text(line.content)
                .font(.system(size: AppTypography.scaled(12), design: .monospaced))
                .foregroundStyle(lineColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .background(lineBackground)
        }
    }

    private var gutterSymbol: String {
        switch line.origin {
        case .added:   return "+"
        case .deleted: return "−"
        case .context: return " "
        }
    }

    private var gutterColor: Color {
        switch line.origin {
        case .added:   return Color.mtHealthy
        case .deleted: return Color.mtError
        case .context: return Color.mtOnSurfaceVariant
        }
    }

    private var gutterBackground: Color {
        switch line.origin {
        case .added:   return Color.mtHealthy.opacity(0.12)
        case .deleted: return Color.mtError.opacity(0.12)
        case .context: return Color.mtSurfaceContainerHighest
        }
    }

    private var lineColor: Color {
        switch line.origin {
        case .added:   return Palette.onSuccessFill
        case .deleted: return Palette.onDangerFill
        case .context: return Color.mtOnSurface
        }
    }

    private var lineBackground: Color {
        switch line.origin {
        case .added:   return Color.mtHealthy.opacity(0.07)
        case .deleted: return Color.mtError.opacity(0.07)
        case .context: return Color.clear
        }
    }
}
#endif
