import Foundation

public struct KnowledgeEvalRow: Sendable, Equatable {
    public var title: String
    public var withParsed: Bool
    public var withoutParsed: Bool
    public var withCount: Int
    public var withoutCount: Int
}

/// Runs the same briefs through the sidecar with and without retrieved guidance. Pure: the caller
/// supplies `run`, so this is testable without a model and the bench supplies the real one.
public enum KnowledgeEval {
    public static func compare(briefs: [Brief],
                               run: @Sendable (Brief, Bool) async throws -> SidecarResult) async -> [KnowledgeEvalRow] {
        func measure(_ b: Brief, _ guided: Bool) async -> (parsed: Bool, count: Int) {
            guard let r = try? await run(b, guided) else { return (false, 0) }
            let n = r.questions.count + r.findings.count + r.revisions.count
            return (n > 0, n)
        }
        var rows: [KnowledgeEvalRow] = []
        for b in briefs {
            let with = await measure(b, true), without = await measure(b, false)
            rows.append(KnowledgeEvalRow(title: b.title, withParsed: with.parsed, withoutParsed: without.parsed,
                                         withCount: with.count, withoutCount: without.count))
        }
        return rows
    }

    public static func summary(_ rows: [KnowledgeEvalRow]) -> String {
        let n = rows.count
        return """
        with guidance: \(rows.filter(\.withParsed).count)/\(n) parsed, \(rows.map(\.withCount).reduce(0, +)) items
        without guidance: \(rows.filter(\.withoutParsed).count)/\(n) parsed, \(rows.map(\.withoutCount).reduce(0, +)) items
        """
    }
}
