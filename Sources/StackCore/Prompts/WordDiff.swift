import Foundation

/// Word-level difference between two texts, for showing what a rewrite changed.
public enum WordDiff {

    public struct Segment: Equatable, Sendable {
        public enum Kind: Sendable { case same, added, removed }
        public let text: String
        public let kind: Kind
    }

    public struct Hunk: Equatable, Sendable, Identifiable {
        public let id: Int
        public let segments: [Segment]
        public var text: String { segments.map(\.text).joined() }
    }

    /// One change in plain terms: what was there, what replaced it, and a few words either side
    /// so a reader can find the place. `id` matches the same hunk in `hunks` and `merge`.
    public struct Change: Equatable, Sendable, Identifiable {
        public enum Kind: Sendable { case added, removed, reworded }
        public let id: Int
        public let before: String
        public let after: String
        public let lead: String
        public let trail: String
        /// The heading the change sits under in the new text, when there is one.
        public let section: String?
        public var kind: Kind { before.isEmpty ? .added : after.isEmpty ? .removed : .reworded }

        /// Code, paths, quoted text and numbers in the old wording that the new wording no longer has.
        public var lostLiterals: [String] {
            PromptLiterals.extract(from: before).filter { !after.contains($0) }
        }

        /// A plain-words guess at why, from the shape of the change. Not what the model intended.
        public var reason: String {
            let vague: Set<String> = ["handle", "properly", "clean", "stuff", "things", "etc", "better", "some",
                                      "good", "nice", "appropriately", "quickly", "simple", "fix", "improve"]
            let old = before.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            switch kind {
            case .added:
                if after.lowercased().contains("unspecified") || after.contains("?") { return "Marks something missing" }
                return PromptLiterals.extract(from: after).isEmpty ? "Adds detail" : "Adds a specific value"
            case .removed:
                return lostLiterals.isEmpty ? "Removes wording" : "Removes a specific detail"
            case .reworded:
                if old.contains(where: vague.contains) { return "Replaces a vague word with something concrete" }
                let b = before.split(whereSeparator: \.isWhitespace).count
                let a = after.split(whereSeparator: \.isWhitespace).count
                return a * 2 > b * 3 ? "Makes it more specific" : a < b ? "Tightens the wording" : "Rephrases"
            }
        }
    }

    /// Segments with short unchanged gaps (two words or fewer) between two edits folded into the edit,
    /// so one rewritten phrase is one change instead of several fragments. Shared by `changes`,
    /// `hunks` and `merge` so their ids always agree.
    static func grouped(from old: String, to new: String, gapWords: Int = 2) -> [Segment] {
        let all = segments(from: old, to: new)
        var out: [Segment] = []
        for (i, segment) in all.enumerated() {
            let between = segment.kind == .same && i > 0 && i < all.count - 1
                && all[i - 1].kind != .same && all[i + 1].kind != .same
                && words(segment.text).count <= gapWords
            if between {
                out.append(Segment(text: segment.text, kind: .removed))
                out.append(Segment(text: segment.text, kind: .added))
            } else {
                out.append(segment)
            }
        }
        return out
    }

    public static func changes(from old: String, to new: String, contextWords: Int = 6) -> [Change] {
        let all = grouped(from: old, to: new)
        var out: [Change] = []
        var index = 0
        var newText = ""
        while index < all.count {
            guard all[index].kind != .same else { newText += all[index].text; index += 1; continue }
            let section = lastHeading(in: newText)
            var before = "", after = ""
            var end = index
            while end < all.count, all[end].kind != .same {
                if all[end].kind == .removed { before += all[end].text } else { after += all[end].text; newText += all[end].text }
                end += 1
            }
            let lead = index > 0 ? words(all[index - 1].text).suffix(contextWords).joined(separator: " ") : ""
            let trail = end < all.count ? words(all[end].text).prefix(contextWords).joined(separator: " ") : ""
            out.append(Change(id: out.count,
                              before: before.trimmingCharacters(in: .whitespacesAndNewlines),
                              after: after.trimmingCharacters(in: .whitespacesAndNewlines),
                              lead: lead, trail: trail, section: section))
            index = end
        }
        return out
    }

    /// The last markdown heading, or short title-like line, before the end of `text`.
    private static func lastHeading(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Unless the text ends at a line break, the final line is cut mid-sentence by the change itself.
        let candidates = text.hasSuffix("\n") ? lines[...] : lines.dropLast()
        for line in candidates.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
            let count = t.split(separator: " ").count
            if count <= 3, let f = t.first, f.isUppercase, !".,;:!?".contains(t.last!) { return t }
        }
        return nil
    }

    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

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

    public static func hunks(from old: String, to new: String) -> [Hunk] {
        hunks(from: grouped(from: old, to: new))
    }

    public static func hunks(from segments: [Segment]) -> [Hunk] {
        var result: [Hunk] = []
        var current: [Segment] = []
        for segment in segments {
            if segment.kind == .same {
                if !current.isEmpty {
                    result.append(Hunk(id: result.count, segments: current))
                    current = []
                }
            } else {
                current.append(segment)
            }
        }
        if !current.isEmpty { result.append(Hunk(id: result.count, segments: current)) }
        return result
    }

    public static func merge(original: String, proposed: String, acceptedHunkIndexes: Set<Int>) -> String {
        let all = grouped(from: original, to: proposed)
        let hunks = hunks(from: all)
        var out = ""
        var hunkIndex = -1
        var inHunk = false
        for segment in all {
            if segment.kind == .same {
                if inHunk { inHunk = false }
                out.append(segment.text)
            } else {
                if !inHunk {
                    hunkIndex += 1
                    inHunk = true
                }
                guard hunkIndex < hunks.count else { continue }
                let accepted = acceptedHunkIndexes.contains(hunks[hunkIndex].id)
                if accepted && segment.kind == .added { out.append(segment.text) }
                if !accepted && segment.kind == .removed { out.append(segment.text) }
            }
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
