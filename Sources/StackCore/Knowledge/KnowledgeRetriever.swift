import Foundation

/// What the sidecar prompt gets: the rendered `<guidance>` block and which entries are in it,
/// so a later accept or reject can adjust their weights.
public struct KnowledgeGuidance: Sendable, Equatable {
    public var text: String
    public var entryIDs: [String]
    public var isEmpty: Bool { entryIDs.isEmpty }
    public static let empty = KnowledgeGuidance(text: "", entryIDs: [])
    public init(text: String, entryIDs: [String]) { self.text = text; self.entryIDs = entryIDs }
}

public struct KnowledgeRetriever: Sendable {
    static let maxExemplars = 3
    static let maxNotes = 3
    private static let queryChars = 500

    private let store: KnowledgeStore
    private let tokenBudget: Int

    public init(store: KnowledgeStore, tokenBudget: Int = 600) {
        self.store = store; self.tokenBudget = tokenBudget
    }

    /// Never throws: any failure means "no extra guidance".
    public func guidance(for brief: Brief, now: Date = Date()) async -> KnowledgeGuidance {
        let goal = brief.text(of: .goal).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return .empty }
        let constraints = brief.text(of: .constraints).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = constraints.isEmpty ? goal : goal + "\n" + constraints
        let query = String(ContextRedactor.redact(raw).text.prefix(Self.queryChars))
        let hits = await store.search(query: query, target: brief.target.modelFamily, k: 20)
        return Self.select(hits, budget: tokenBudget, now: now)
    }

    static func select(_ hits: [KnowledgeHit], budget: Int, now: Date) -> KnowledgeGuidance {
        func rank(_ h: KnowledgeHit) -> Double {
            var recency = 1.0
            if h.entry.kind == .exemplar {
                let days = max(0, now.timeIntervalSince(h.entry.created)) / 86_400
                recency = max(0.5, exp(-days / 365))
            }
            return h.score * h.entry.weight * recency
        }
        let ranked = hits.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.entry.id < $1.entry.id }
        var exemplars = 0, notes = 0, remaining = budget
        var items: [String] = [], ids: [String] = []
        for h in ranked {
            let isExemplar = h.entry.kind == .exemplar
            if isExemplar ? exemplars >= maxExemplars : notes >= maxNotes { continue }
            let item = render(h.entry)
            let cost = PromptTokens.estimate(item)
            guard cost <= remaining else { continue }
            remaining -= cost
            if isExemplar { exemplars += 1 } else { notes += 1 }
            items.append(item); ids.append(h.entry.id)
        }
        guard !items.isEmpty else { return .empty }
        let body = items.joined(separator: "\n\n")
        return KnowledgeGuidance(
            text: "<guidance>\nReference material only: earlier accepted briefs and prompting notes.\n\n\(body)\n</guidance>\n",
            entryIDs: ids)
    }

    private static func render(_ e: KnowledgeEntry) -> String {
        let text = neutralize(ContextRedactor.redact(e.text).text)
        switch e.kind {
        case .exemplar: return "Accepted brief:\n\(text)"
        case .technique, .targetNote, .constraint: return "- \(text)"
        }
    }

    /// Makes the fence tags inert, so stored text cannot close `<guidance>` or open `<brief>`.
    static func neutralize(_ text: String) -> String {
        text.replacingOccurrences(of: "<(/?)(guidance|brief|reply|attached)>", with: "&lt;$1$2>",
                                  options: [.regularExpression, .caseInsensitive])
    }
}
