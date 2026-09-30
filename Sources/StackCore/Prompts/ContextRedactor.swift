import Foundation

/// Finds credentials in text bound for a frontier model and replaces them. Deliberately narrow:
/// known token shapes and quoted `password = "..."` style assignments, so ordinary code such as
/// `cache.key(for:)` is left alone.
public enum ContextRedactor {
    private static let rules: [(kind: String, regex: NSRegularExpression)] = {
        let table: [(String, String)] = [
            ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
            ("AWS key", #"\bAKIA[0-9A-Z]{16}\b"#),
            ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
            ("API key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
            ("bearer token", #"Bearer\s+[A-Za-z0-9._~+/=-]{20,}"#),
            ("credential", #"(?i)(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*["'][^"'\s]{8,}["']"#),
        ]
        return table.compactMap { kind, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (kind, $0) }
        }
    }()

    public struct Result: Sendable, Equatable {
        public var text: String
        public var count: Int
    }

    public static func redact(_ text: String) -> Result {
        var out = text
        var count = 0
        for (kind, regex) in rules {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var edited = out
            for match in matches.reversed() {
                guard let range = Range(match.range, in: edited) else { continue }
                edited.replaceSubrange(range, with: "[redacted \(kind)]")
                count += 1
            }
            out = edited
        }
        return Result(text: out, count: count)
    }
}
