import Foundation

/// Decides which parts of a long conversation to shrink so a local prompt stays under
/// `ContextBudget`'s ceiling, touching as little as possible so the prompt-prefix cache survives.
///
/// Pure: no I/O and no model calls. The caller measures tokens, runs the plan, and stores the
/// result as ordinary transcript messages (so the rewrite happens once and then stays frozen).
public struct CompactionPlanner: Sendable, Equatable {

    /// One transcript message as the planner sees it.
    public struct Item: Sendable, Equatable {
        public var role: Message.Role
        public var tokens: Int
        /// User-pinned: never elided or summarized.
        public var isPinned: Bool
        /// Came from web/MCP/cloud text; carried onto whatever replaces it.
        public var isUntrusted: Bool
        /// The part of this message that can be replaced by a stub: all of a tool result, or the
        /// retrieved-code block inside a user turn. Nil means the default (tool: everything, else none).
        public var bulkTokens: Int?

        public init(role: Message.Role, tokens: Int, isPinned: Bool = false, isUntrusted: Bool = false, bulkTokens: Int? = nil) {
            self.role = role
            self.tokens = tokens
            self.isPinned = isPinned
            self.isUntrusted = isUntrusted
            self.bulkTokens = bulkTokens
        }

        var elidableTokens: Int { bulkTokens ?? (role == .tool ? tokens : 0) }
    }

    public enum Outcome: Sendable, Equatable {
        /// Under the trigger; leave the transcript alone.
        case none
        /// The plan reaches the target.
        case compact
        /// The plan cannot reach the target; the caller routes per Router rules (cloud or new chat).
        /// `hardFit` says whether the plan at least gets under the ceiling.
        case insufficient(hardFit: Bool)
    }

    public struct Plan: Sendable, Equatable {
        public var outcome: Outcome
        /// Indices of tool messages to replace with a short stub.
        public var elide: [Int]
        /// Contiguous range to replace with one summary message (nil unless summarizing is allowed and needed).
        public var summarize: Range<Int>?
        /// The summary must carry the untrusted flag when any summarized message had it.
        public var summaryIsUntrusted: Bool
        public var tokensBefore: Int
        public var tokensAfter: Int
    }

    /// Start compacting above this fraction of the ceiling.
    public var triggerFraction: Double
    /// Compact down to this fraction, so the next compaction is many turns away.
    public var targetFraction: Double
    /// The last N user turns (and everything after) are left verbatim, unless that alone would keep
    /// the prompt above the target; then the window shrinks, down to `minKeepRecentTurns`.
    public var keepRecentTurns: Int
    public var minKeepRecentTurns: Int
    /// Tool output smaller than this is not worth a stub.
    public var minElideTokens: Int
    /// What a stub costs.
    public var stubTokens: Int
    /// What a summary costs (planning estimate).
    public var summaryTokens: Int
    /// Off for the local model until the summary-quality gate passes.
    public var allowSummarize: Bool
    /// Leading messages that make up the stable prefix (system prompt, pinned context); never touched.
    public var stablePrefixCount: Int

    public init(triggerFraction: Double = 0.78, targetFraction: Double = 0.35, keepRecentTurns: Int = 4,
                minKeepRecentTurns: Int = 2, minElideTokens: Int = 400, stubTokens: Int = 30, summaryTokens: Int = 600,
                allowSummarize: Bool = false, stablePrefixCount: Int = 1) {
        self.triggerFraction = triggerFraction
        self.targetFraction = targetFraction
        self.keepRecentTurns = keepRecentTurns
        self.minKeepRecentTurns = min(minKeepRecentTurns, keepRecentTurns)
        self.minElideTokens = minElideTokens
        self.stubTokens = stubTokens
        self.summaryTokens = summaryTokens
        self.allowSummarize = allowSummarize
        self.stablePrefixCount = stablePrefixCount
    }

    public func plan(items: [Item], maxPromptTokens: Int) -> Plan {
        let before = items.reduce(0) { $0 + $1.tokens }
        let trigger = Int(Double(maxPromptTokens) * triggerFraction)
        let target = Int(Double(maxPromptTokens) * targetFraction)
        func plan(_ outcome: Outcome, elide: [Int] = [], summarize: Range<Int>? = nil,
                  untrusted: Bool = false, after: Int) -> Plan {
            Plan(outcome: outcome, elide: elide, summarize: summarize, summaryIsUntrusted: untrusted,
                 tokensBefore: before, tokensAfter: after)
        }
        guard before > trigger else { return plan(.none, after: before) }

        let start = min(stablePrefixCount, items.count)
        let end = protectedBoundary(items, from: start, target: target)   // items[start..<end] may be shrunk
        var total = before

        // Step 1: stub old bulky tool output, oldest first, until the target is met.
        var elide: [Int] = []
        for i in start..<end where total > target {
            let item = items[i]
            guard canElide(item) else { continue }
            elide.append(i)
            total -= item.elidableTokens - stubTokens
        }
        if total <= target { return plan(.compact, elide: elide, after: total) }

        // Step 2: summarize the oldest shrinkable run, if allowed.
        if allowSummarize, let run = summarizableRun(items, in: start..<end, skipping: Set(elide)) {
            let saved = items[run].enumerated().reduce(0) { sum, pair in
                sum + (elide.contains(run.lowerBound + pair.offset)
                       ? pair.element.tokens - pair.element.elidableTokens + stubTokens : pair.element.tokens)
            }
            let after = total - saved + summaryTokens
            if saved > summaryTokens {
                let untrusted = items[run].contains { $0.isUntrusted }
                let kept = elide.filter { !run.contains($0) }
                return plan(after <= target ? .compact : .insufficient(hardFit: after <= maxPromptTokens),
                            elide: kept, summarize: run, untrusted: untrusted, after: after)
            }
        }
        return plan(.insufficient(hardFit: total <= maxPromptTokens), elide: elide, after: total)
    }

    /// Index of the first message in the protected recent window: the largest window (down to
    /// `minKeepRecentTurns` turns) for which clearing every older tool result would reach the
    /// target. A window that can't reach it would make compaction fire again a turn or two later.
    /// Everything before the returned index, after the stable prefix, may be shrunk.
    private func protectedBoundary(_ items: [Item], from start: Int, target: Int) -> Int {
        var boundary = start
        for turns in stride(from: keepRecentTurns, through: minKeepRecentTurns, by: -1) {
            boundary = firstIndex(ofRecentTurns: turns, items, from: start)
            var reachable = 0
            for (i, item) in items.enumerated() {
                reachable += i >= start && i < boundary && canElide(item) ? item.tokens - item.elidableTokens + stubTokens : item.tokens
            }
            if reachable <= target { return boundary }
        }
        return boundary
    }

    private func canElide(_ item: Item) -> Bool {
        !item.isPinned && item.elidableTokens >= minElideTokens && item.elidableTokens > stubTokens
    }

    /// Index of the `turns`-th user message from the end (or `start` if there are fewer).
    private func firstIndex(ofRecentTurns turns: Int, _ items: [Item], from start: Int) -> Int {
        var seen = 0
        for i in stride(from: items.count - 1, through: start, by: -1) where items[i].role == .user {
            seen += 1
            if seen == turns { return i }
        }
        return start
    }

    /// Oldest contiguous run of unpinned messages, starting at a user turn and ending just before
    /// the next user turn so a turn is never split.
    private func summarizableRun(_ items: [Item], in range: Range<Int>, skipping: Set<Int>) -> Range<Int>? {
        var lower: Int?
        for i in range {
            if items[i].isPinned || items[i].role == .system {
                if let l = lower, i > l { return trimmed(items, l..<i) }
                lower = nil
                continue
            }
            if lower == nil, items[i].role == .user { lower = i }
        }
        if let l = lower { return trimmed(items, l..<range.upperBound) }
        return nil
    }

    /// Drop a trailing partial turn (messages after the run's last user message stay only if they
    /// end right before another user message or the recent window).
    private func trimmed(_ items: [Item], _ run: Range<Int>) -> Range<Int>? {
        run.count >= 2 ? run : nil
    }
}
