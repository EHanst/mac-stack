import Foundation

/// Word-level difference between two texts, for showing what a rewrite changed.
public enum WordDiff {

    public struct Segment: Equatable, Sendable {
        public enum Kind: Sendable { case same, added, removed }
        public let text: String
        public let kind: Kind
    }

    public static func segments(from old: String, to new: String) -> [Segment] {
        let a = tokens(old), b = tokens(new)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Segment] = []
        func add(_ text: String, _ kind: Segment.Kind) {
            if let last = out.last, last.kind == kind {
                out[out.count - 1] = Segment(text: last.text + text, kind: kind)
            } else {
                out.append(Segment(text: text, kind: kind))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { add(a[i], .removed); i += 1 }
            else if j < b.count, inserted.contains(j) { add(b[j], .added); j += 1 }
            else if i < a.count { add(a[i], .same); i += 1; j += 1 }
            else { add(b[j], .added); j += 1 }
        }
        return out
    }

    /// Words and the whitespace between them, as separate tokens, so joining them gives the text back.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace: Bool?
        for ch in text {
            let space = ch.isWhitespace
            if let state = inSpace, state != space { out.append(current); current = "" }
            inSpace = space
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
