import Foundation

/// The parts of a prompt a rewrite must not lose: code, paths, quoted text, numbers and
/// identifiers. Checked by program, not by asking the model, so a rewrite that drops one is
/// rejected no matter how confident it sounds.
public enum PromptLiterals {

    public static func extract(from text: String) -> [String] {
        var found: [String] = []
        var rest = text

        // Fenced code blocks, whole.
        let fence = try? NSRegularExpression(pattern: "```[\\s\\S]*?```")
        for m in matches(fence, in: rest) { found.append(m) }
        rest = replacing(fence, in: rest)

        // Inline code.
        let inline = try? NSRegularExpression(pattern: "`[^`\\n]+`")
        for m in matches(inline, in: rest) { found.append(m) }
        rest = replacing(inline, in: rest)

        let patterns = [
            "\"[^\"\\n]{2,}\"",                                                            // "quoted text"
            "[\\w.-]+(?:/[\\w.-]+)+",                                                       // a/b/c paths
            "\\b[\\w-]+\\.(?:swift|md|json|yml|yaml|plist|txt|py|js|ts|c|h|m|sh|toml)\\b",  // file names
            "\\b\\d+(?:[.,]\\d+)+\\b|\\b\\d{2,}\\b",                                          // numbers
            "\\b[a-z]+[A-Z][A-Za-z0-9]*\\b|\\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\\b|\\b[A-Za-z]+_[A-Za-z0-9_]+\\b", // identifiers
        ]
        for p in patterns {
            let re = try? NSRegularExpression(pattern: p)
            for m in matches(re, in: rest) { found.append(m) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    private static let stopwords: Set<String> = [
        "about", "above", "after", "again", "also", "because", "been", "before", "being", "could", "does", "doing",
        "each", "from", "have", "having", "here", "into", "just", "like", "make", "more", "most", "need", "only",
        "other", "should", "some", "such", "than", "that", "their", "them", "then", "there", "these", "they", "this",
        "those", "through", "want", "were", "what", "when", "where", "which", "while", "will", "with", "would", "your",
        "please", "using", "used", "work", "working", "something", "thing", "things", "really", "very",
    ]

    /// Plain words from `original` the rewrite should still carry: the requirements a short prose request is made of
    /// ("speed", "size"), which the literal check can't see. Matches on a 5-letter stem so "faster"/"fast" and
    /// "optimizing"/"optimize" don't count as dropped. Short drafts must keep every term; long ones may reword
    /// up to a quarter of theirs.
    public static func missingTerms(from original: String, in rewritten: String) -> [String] {
        func stem(_ w: String) -> String { String(w.prefix(w.count > 5 ? 5 : w.count)) }
        let words = original.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        var seen = Set<String>()
        let terms = words.filter { $0.count >= 4 && !stopwords.contains($0) && seen.insert(stem($0)).inserted }
        guard !terms.isEmpty else { return [] }
        let haystack = rewritten.lowercased()
        let missing = terms.filter { !haystack.contains(stem($0)) }
        let allowed = words.count <= 60 ? 0 : terms.count / 4
        return missing.count > allowed ? missing : []
    }

    /// Literals from `original` that don't appear in `rewritten`.
    public static func missing(from original: String, in rewritten: String) -> [String] {
        extract(from: original).filter { !isPresent($0, in: rewritten) }
    }

    /// The literal appears as written, or (for inline code and quoted text) its contents appear without
    /// the backticks or quotes around them. Dropping only the wrapper leaves the words intact, which is
    /// not worth throwing a rewrite away for. Fenced blocks stay exact, and short contents (under 4
    /// characters) must keep their wrapper, since a bare "x" would match almost anywhere.
    static func isPresent(_ literal: String, in rewritten: String) -> Bool {
        if rewritten.contains(literal) { return true }
        guard !literal.hasPrefix("```"),
              let first = literal.first, first == "`" || first == "\"",
              literal.count > 2, literal.last == first
        else { return false }
        let inner = String(literal.dropFirst().dropLast())
        guard inner.count >= 4 else { return false }
        // Quoted prose may be recapitalized when the rewrite moves it; code is case-sensitive.
        return first == "\"" ? rewritten.localizedCaseInsensitiveContains(inner) : rewritten.contains(inner)
    }

    private static func matches(_ re: NSRegularExpression?, in text: String) -> [String] {
        guard let re else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func replacing(_ re: NSRegularExpression?, in text: String) -> String {
        guard let re else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
    }
}
