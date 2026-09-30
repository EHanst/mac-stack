import Foundation

/// The opt-in for recording accepted briefs, plus the counters that decide when to ask again.
/// Only counters and ids are kept here; brief text never is.
public struct KnowledgeSettings: Sendable {
    public enum Decision: String, Sendable { case undecided, enabled, declined }
    public enum Prompt: Sendable, Equatable { case card, nudge }

    // UserDefaults is thread-safe but not marked Sendable in this SDK.
    private nonisolated(unsafe) let defaults: UserDefaults
    private enum Key {
        static let decision = "knowledge.decision"
        static let cardDismissed = "knowledge.cardDismissed"
        static let nudgeDismissals = "knowledge.nudgeDismissals"
        static let acceptedIDs = "knowledge.acceptedBriefIDs"
    }
    private static let maxTrackedIDs = 50

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var decision: Decision {
        defaults.string(forKey: Key.decision).flatMap(Decision.init(rawValue:)) ?? .undecided
    }
    public var isRecording: Bool { decision == .enabled }
    public func setDecision(_ d: Decision) { defaults.set(d.rawValue, forKey: Key.decision) }

    public var acceptedBriefCount: Int { (defaults.stringArray(forKey: Key.acceptedIDs) ?? []).count }

    /// Counts distinct briefs the user has accepted, whether or not recording is on.
    public func noteAcceptEvent(briefID: String) {
        var ids = defaults.stringArray(forKey: Key.acceptedIDs) ?? []
        guard !ids.contains(briefID), ids.count < Self.maxTrackedIDs else { return }
        ids.append(briefID)
        defaults.set(ids, forKey: Key.acceptedIDs)
    }

    public func dismissCard() { defaults.set(true, forKey: Key.cardDismissed) }
    public func dismissNudge() { defaults.set(defaults.integer(forKey: Key.nudgeDismissals) + 1, forKey: Key.nudgeDismissals) }

    public var prompt: Prompt? {
        let count = acceptedBriefCount
        if decision == .undecided, !defaults.bool(forKey: Key.cardDismissed), count == 0 { return .card }
        guard decision == .undecided else { return nil }
        let dismissals = defaults.integer(forKey: Key.nudgeDismissals)
        if (dismissals == 0 && count >= 1) || (dismissals == 1 && count >= 6) { return .nudge }
        return nil
    }
}
