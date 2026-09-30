import Foundation

/// Finds credentials in text bound for a frontier model and replaces them. It aims at the shapes
/// that leak in practice (provider tokens, key blocks, `.env` and JSON config lines, quoted
/// assignments) while leaving ordinary code such as `cache.key(for:)` or `let token: String` alone.
/// Every pattern is bounded so a hostile file cannot make it run in quadratic time.
public enum ContextRedactor {
    private struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// Which capture group holds the secret; 0 replaces the whole match.
        let group: Int
    }

    private static let keyword = #"(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|auth[_-]?token|token|credential)"#
    private static let unquoted = #"(?![\[\"'])(?=[^\s\"',;#]*\d)[A-Za-z0-9+/=_.~!@$%^&*-]{8,}"#

    private static let rules: [Rule] = {
        let table: [(String, String, Int)] = [
            // Whole key blocks, then any BEGIN line whose END is missing (cut off, or a fragment).
            ("private key", #"-----BEGIN [A-Z ]{0,30}PRIVATE KEY[A-Z ]{0,10}-----[A-Za-z0-9+/=:,.\s-]{0,8192}?-----END [A-Z ]{0,30}PRIVATE KEY[A-Z ]{0,10}-----"#, 0),
            ("private key", #"-----BEGIN [A-Z ]{0,30}PRIVATE KEY[A-Z ]{0,10}-----(?:\s*[A-Za-z0-9+/=:,. -]{1,200}){0,200}"#, 0),
            ("AWS key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, 0),
            ("GitHub token", #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})"#, 0),
            ("API key", #"\bsk[-_][A-Za-z0-9_-]{20,}"#, 0),
            ("Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, 0),
            ("Google key", #"\bAIza[0-9A-Za-z_-]{35}"#, 0),
            ("bearer token", #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}"#, 0),
            // `name = "value"`, `name: 'value'`, `"name": "value"` and `NAME=value` where name mentions a credential.
            ("credential", "(?i)[A-Za-z0-9_.-]{0,40}" + keyword + #"[A-Za-z0-9_.-]{0,40}["']?\s*[:=]\s*(?:"(?!\[redacted)([^"\n]{6,})"|'(?!\[redacted)([^'\n]{6,})'|("# + unquoted + "))", 0),
        ]
        return table.compactMap { kind, pattern, group in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(kind: kind, regex: $0, group: group) }
        }
    }()

    public struct Result: Sendable, Equatable {
        public var text: String
        public var count: Int
    }

    public static func redact(_ text: String) -> Result {
        var out = text
        var count = 0
        for rule in rules {
            let matches = rule.regex.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length))
            guard !matches.isEmpty else { continue }
            for match in matches.reversed() {
                // For assignment rules keep the name and replace only the value (the first group that matched).
                let range = (1..<max(match.numberOfRanges, 1)).lazy
                    .map { match.range(at: $0) }.first { $0.location != NSNotFound } ?? match.range
                let target = rule.group == 0 && match.numberOfRanges > 1 ? range : match.range
                guard let r = Range(target, in: out) else { continue }
                out.replaceSubrange(r, with: "[redacted \(rule.kind)]")
                count += 1
            }
        }
        return Result(text: out, count: count)
    }
}
