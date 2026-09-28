import Foundation
import Crypto

public struct BuildFailureFingerprint: Sendable, Hashable {

    public let rawValue: Data

    public init(normalizing stderr: String) {
        let normalized = Self.normalize(stderr)
        rawValue = Data(SHA256.hash(data: Data(normalized.utf8)))
    }

    public static func normalize(_ stderr: String) -> String {
        var s = stderr
        // Strip absolute Swift file paths with line:col (e.g. /path/Foo.swift:12:5:)
        s = s.replacingOccurrences(
            of: #"\/[^\s:]+\.swift:\d+:\d+:"#,
            with: "<file>:",
            options: .regularExpression
        )
        // Strip PID/TID annotations like [1234:5678]
        s = s.replacingOccurrences(of: #"\[\d+:\d+\]"#, with: "", options: .regularExpression)
        // Strip ISO timestamps like 2026-01-15 14:23:55.123
        s = s.replacingOccurrences(
            of: #"\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?"#,
            with: "",
            options: .regularExpression
        )
        // Collapse runs of whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
