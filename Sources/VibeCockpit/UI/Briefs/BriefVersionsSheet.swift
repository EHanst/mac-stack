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
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(brief.versions.enumerated().reversed()), id: \.offset) { index, version in
                            Button { selection = index } label: {
                                Text(version.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.mtBodyMedium)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(selection == index ? Color.mtPrimary.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
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
            let rows = BriefVersionDiff.rows(currentInput: brief.input, currentBody: brief.body,
                                             version: brief.versions[selection])
            if rows.isEmpty {
                Text("No differences from the current text.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.field == .input ? "Input" : "Brief")
                                .font(.mtLabelSmall)
                                .foregroundStyle(Color.mtOnSurfaceVariant)
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
