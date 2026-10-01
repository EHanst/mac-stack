#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI

/// Saved versions of a brief, with what restoring each would change.
struct BriefVersionsSheet: View {
    let brief: Brief
    let onRestore: (Int) -> Void
    let onClose: () -> Void

    private enum Mode: String, CaseIterable { case restore = "Restore", compare = "Compare" }
    @State private var mode: Mode = .restore
    @State private var selection: Int?
    @State private var compareA: Int = 0
    @State private var compareB: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Versions").font(.mtTitleMedium)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(brief.versions.enumerated().reversed()), id: \.offset) { index, version in
                            Button { if mode == .restore { selection = index } } label: {
                                Text(version.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.mtBodyMedium)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(selection == index && mode == .restore ? Color.mtPrimary.opacity(0.2) : Color.clear)
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
                if mode == .restore {
                    Button("Restore this version") { if let selection { onRestore(selection); onClose() } }
                        .buttonStyle(MTFilledButtonStyle())
                        .disabled(!brief.versions.indices.contains(selection ?? -1))
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
        .onAppear { clampCompareSelections() }
        .onChange(of: brief.versions.count) { _ in clampCompareSelections() }
    }

    @ViewBuilder private var detail: some View {
        switch mode {
        case .restore: restoreDetail
        case .compare: compareDetail
        }
    }

    @ViewBuilder private var restoreDetail: some View {
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

    @ViewBuilder private var compareDetail: some View {
        if brief.versions.indices.contains(compareA), brief.versions.indices.contains(compareB) {
            let a = brief.versions[compareA]
            let b = brief.versions[compareB]
            let rows = BriefVersionDiff.rows(currentInput: a.input, currentBody: a.body, version: b)
            VStack(alignment: .leading, spacing: 10) {
                Picker("From", selection: $compareA) {
                    ForEach(Array(brief.versions.enumerated().reversed()), id: \.offset) { index, version in
                        Text(version.date.formatted(date: .abbreviated, time: .shortened)).tag(index)
                    }
                }
                .labelsHidden()
                Picker("To", selection: $compareB) {
                    ForEach(Array(brief.versions.enumerated().reversed()), id: \.offset) { index, version in
                        Text(version.date.formatted(date: .abbreviated, time: .shortened)).tag(index)
                    }
                }
                .labelsHidden()
                if rows.isEmpty {
                    Text("No differences.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                } else {
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
            Text("Pick two versions to compare.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private func clampCompareSelections() {
        guard !brief.versions.isEmpty else { return }
        if compareA >= brief.versions.count { compareA = brief.versions.count - 1 }
        if compareB >= brief.versions.count { compareB = brief.versions.count - 1 }
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
