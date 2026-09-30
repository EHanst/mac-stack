import Foundation

/// Turns "the user accepted this brief" into a stored exemplar, and sidecar accept/reject clicks into
/// weight changes. Writes nothing unless the user opted in. Never throws: a failed write must not
/// get in the way of the action that triggered it.
public struct KnowledgeRecorder: Sendable {
    private let store: KnowledgeStore
    private let settings: KnowledgeSettings

    public init(store: KnowledgeStore, settings: KnowledgeSettings) {
        self.store = store; self.settings = settings
    }

    public func recordAccepted(_ brief: Brief, now: Date = Date()) async {
        settings.noteAcceptEvent(briefID: brief.id)
        guard settings.isRecording, let entry = Self.exemplar(from: brief, now: now) else { return }
        // One exemplar per brief: the latest accepted version replaces its earlier ones.
        if let added = try? await store.addAll([entry]), added > 0 {
            try? await store.deleteExemplars(briefID: brief.id, except: entry.id)
        }
    }

    public func recordSignal(ids: [String], outcome: SignalOutcome) async {
        guard settings.isRecording, !ids.isEmpty else { return }
        try? await store.applySignal(ids: ids, outcome: outcome)
    }

    /// The sections the user settled on, redacted. Attached context (file text, diffs) is deliberately left out.
    public static func exemplar(from brief: Brief, now: Date) -> KnowledgeEntry? {
        let goal = ContextRedactor.redact(brief.text(of: .goal)).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard brief.sections.first(where: { $0.kind == .goal })?.enabled == true, !goal.isEmpty else { return nil }
        var parts: [String] = []
        for kind in BriefSection.Kind.allCases {
            guard let s = brief.sections.first(where: { $0.kind == kind }), s.enabled else { continue }
            let text = ContextRedactor.redact(s.text).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append("## \(kind.rawValue)\n\(text)") }
        }
        let intent = String(goal.replacingOccurrences(of: "\n", with: " ").prefix(200))
        return KnowledgeEntry(kind: .exemplar, target: brief.target.modelFamily,
                              text: String(parts.joined(separator: "\n\n").prefix(KnowledgeLimits.maxTextChars)),
                              meta: ["intent": intent, "surface": brief.target.surface.rawValue, "briefID": brief.id], created: now)
    }
}
