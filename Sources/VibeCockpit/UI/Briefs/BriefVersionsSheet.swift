#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI

/// Saved versions of a brief, with what restoring each would change.
struct BriefVersionsSheet: View {
    let brief: Brief
    let onRestore: (Int) -> Void
    let onClose: () -> Void
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Versions").font(.mtTitleMedium)
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(brief.versions.enumerated().reversed()), id: \.offset) { index, version in
                        Text(version.date.formatted(date: .abbreviated, time: .shortened)).tag(Optional(index))
                    }
                }
                .frame(width: 180)
                ScrollView { detail }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose)
                Button("Restore this version") { if let selection { onRestore(selection); onClose() } }
                    .buttonStyle(MTFilledButtonStyle())
                    .disabled(!brief.versions.indices.contains(selection ?? -1))
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }

    @ViewBuilder private var detail: some View {
        if let selection, brief.versions.indices.contains(selection) {
            let rows = BriefVersionDiff.rows(current: brief.sections, version: brief.versions[selection])
            if rows.isEmpty {
                Text("No differences from the current text.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(BriefWorkbenchView.title(row.kind)).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                            Self.diffText(row.segments).font(.mtBodyMedium)
                        }
                    }
                }
            }
        } else {
            Text("Pick a version to see what restoring it changes.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    /// Shared with the revision cards: removed text struck through, added text highlighted.
    static func diffText(_ segments: [WordDiff.Segment]) -> Text {
        segments.reduce(Text("")) { acc, seg in
            switch seg.kind {
            case .same: acc + Text(seg.text)
            case .added: acc + Text(seg.text).foregroundColor(Color.mtPrimary)
            case .removed: acc + Text(seg.text).strikethrough().foregroundColor(Color.mtError)
            }
        }
    }
}
#endif
