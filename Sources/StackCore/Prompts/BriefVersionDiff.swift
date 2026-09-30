import Foundation

/// What restoring a version would change, one row per section that differs.
public enum BriefVersionDiff {
    public struct Row: Equatable, Identifiable {
        public let kind: BriefSection.Kind
        public let segments: [WordDiff.Segment]
        public var id: BriefSection.Kind { kind }
    }

    /// Segments run from the current text to the version's: `added` comes back on restore, `removed` goes away.
    public static func rows(current: [BriefSection], version: Brief.Version) -> [Row] {
        BriefSection.Kind.allCases.compactMap { kind in
            let now = current.first { $0.kind == kind }?.text ?? ""
            let then = version.sections.first { $0.kind == kind }?.text ?? ""
            guard now != then else { return nil }
            return Row(kind: kind, segments: WordDiff.segments(from: now, to: then))
        }
    }
}
