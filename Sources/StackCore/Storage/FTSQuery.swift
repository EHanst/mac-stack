import Foundation

/// Turns a natural-language or identifier-style query into an FTS5 MATCH expression.
///
/// Wrapping the whole query in quotes (the previous behaviour) makes it a *phrase* search, so a
/// question like "how do we cut prefill at message boundaries" only matched if those exact words
/// appeared consecutively — i.e. almost never. Here each meaningful word becomes a quoted
/// prefix term and the terms are OR-ed, so `bm25()` ranks chunks by how many rare terms they hit.
/// Prefix matching lets "prefill" find `PrefillPlan`, because FTS5's default tokenizer keeps
/// camelCase identifiers whole.
public enum FTSQuery {

    private static let stopwords: Set<String> = [
        "the", "an", "of", "to", "in", "is", "are", "do", "does", "how", "what", "where", "when",
        "why", "which", "who", "we", "our", "and", "or", "for", "on", "with", "this", "that",
        "it", "its", "you", "your", "from", "by", "as", "at", "be", "can", "has", "have", "i",
        "my", "me", "there", "any", "all", "if", "not", "into", "than", "then", "so", "use",
        "used", "using", "code", "function", "class", "find", "show", "get",
    ]

    /// Split into lowercase words, also breaking camelCase / snake_case identifiers apart while
    /// keeping the whole identifier as a term too.
    static func terms(from query: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ t: String) {
            let w = t.lowercased()
            guard w.count >= 2, !stopwords.contains(w), seen.insert(w).inserted else { return }
            out.append(w)
        }
        let separators = CharacterSet.alphanumerics.inverted
        for raw in query.components(separatedBy: separators) where !raw.isEmpty {
            add(raw)
            for part in splitCamelCase(raw) where part.lowercased() != raw.lowercased() { add(part) }
        }
        return Array(out.prefix(12))
    }

    private static func splitCamelCase(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(word)
        for (i, ch) in chars.enumerated() {
            let startsWord = ch.isUppercase && !current.isEmpty
                && (!chars[i - 1].isUppercase || (i + 1 < chars.count && chars[i + 1].isLowercase))
            if startsWord { parts.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// nil when the query has no searchable terms.
    public static func match(_ query: String) -> String? {
        let terms = terms(from: query)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
