import Foundation

/// What restoring a version would change, one row per field that differs.
public enum BriefVersionDiff {
    public enum Field: String, Equatable { case input, body }

    public struct Row: Equatable, Identifiable {
        public let field: Field
        public let segments: [WordDiff.Segment]
        public var id: Field { field }
    }

    /// Segments run from the current text to the version's: `added` comes back on restore, `removed` goes away.
    public static func rows(currentInput: String, currentBody: String?, version: Brief.Version) -> [Row] {
        var rows: [Row] = []
        if currentInput != version.input {
            rows.append(Row(field: .input, segments: WordDiff.segments(from: currentInput, to: version.input)))
        }
        let nowBody = currentBody ?? ""
        let thenBody = version.body ?? ""
        if nowBody != thenBody {
            rows.append(Row(field: .body, segments: WordDiff.segments(from: nowBody, to: thenBody)))
        }
        return rows
    }
}
