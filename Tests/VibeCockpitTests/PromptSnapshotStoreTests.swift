import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("PromptSnapshotStore")
struct PromptSnapshotStoreTests {

    private func toks(_ n: Int, base: Int32 = 0) -> [Int32] { (0..<n).map { base + Int32($0) } }

    @Test("bestMatch restores the longest stored prefix, not all-or-nothing")
    func partialMatch() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(10), payload: "system", bytes: 1, kind: .system)
        s.insert(tokens: toks(30), payload: "turn1", bytes: 1, kind: .boundary)
        s.insert(tokens: toks(50), payload: "turn2", bytes: 1, kind: .boundary)
        // New prompt shares 35 tokens with history, then diverges.
        var prompt = toks(35); prompt += [999, 998, 997]
        #expect(s.bestMatch(for: prompt, maxLength: prompt.count - 1)?.payload == "turn1")
        // Diverges inside the system prompt: nothing reusable.
        var other = toks(5); other += [777, 776]
        #expect(s.bestMatch(for: other, maxLength: other.count - 1) == nil)
    }

    @Test("only one system snapshot is kept: a new system prompt supersedes the old one")
    func singleSystemEntry() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(10), payload: "sysA", bytes: 1, kind: .system)
        s.insert(tokens: toks(12, base: 500), payload: "sysB", bytes: 1, kind: .system)
        s.insert(tokens: toks(30, base: 500), payload: "turn", bytes: 1, kind: .boundary)
        #expect(Set(s.entries.map(\.payload)) == ["sysB", "turn"])
        s.prune(keepingPrefixesOf: toks(40, base: 500))
        #expect(Set(s.entries.map(\.payload)) == ["sysB", "turn"])
    }

    @Test("bestMatch never returns an entry longer than maxLength")
    func respectsMaxLength() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(20), payload: "a", bytes: 1, kind: .boundary)
        #expect(s.bestMatch(for: toks(20), maxLength: 19) == nil)
        #expect(s.bestMatch(for: toks(21), maxLength: 20)?.payload == "a")
    }

    @Test("a new tail replaces the old tail; identical token runs are replaced")
    func replacement() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(40), payload: "tail1", bytes: 1, kind: .tail)
        s.insert(tokens: toks(60), payload: "tail2", bytes: 1, kind: .tail)
        #expect(s.entries.map(\.payload) == ["tail2"])
        s.insert(tokens: toks(60), payload: "b", bytes: 1, kind: .boundary)
        #expect(s.entries.map(\.payload) == ["b"])
    }

    @Test("prune drops dead branches but keeps the system snapshot for the next session")
    func pruneDeadBranches() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(10), payload: "system", bytes: 1, kind: .system)
        s.insert(tokens: toks(10) + [500, 501, 502], payload: "old-branch", bytes: 1, kind: .boundary)
        s.insert(tokens: toks(25), payload: "live", bytes: 1, kind: .boundary)
        s.prune(keepingPrefixesOf: toks(40))
        #expect(Set(s.entries.map(\.payload)) == ["system", "live"])
        // Session cleared: a brand-new conversation still shares the system prefix.
        s.prune(keepingPrefixesOf: toks(10) + [900, 901])
        #expect(s.entries.map(\.payload) == ["system"])
    }

    @Test("over the caps, shortest non-system prefix is evicted first; system and longest survive")
    func evictionOrder() {
        var s = PromptSnapshotStore<String>(maxEntries: 3, maxBytes: .max)
        s.insert(tokens: toks(10), payload: "system", bytes: 1, kind: .system)
        s.insert(tokens: toks(20), payload: "b20", bytes: 1, kind: .boundary)
        s.insert(tokens: toks(30), payload: "b30", bytes: 1, kind: .boundary)
        s.insert(tokens: toks(40), payload: "b40", bytes: 1, kind: .boundary)
        s.prune(keepingPrefixesOf: toks(50))
        #expect(Set(s.entries.map(\.payload)) == ["system", "b30", "b40"])
    }

    @Test("byte cap evicts, but never the system entry or the longest")
    func byteCap() {
        var s = PromptSnapshotStore<String>(maxEntries: 10, maxBytes: 100)
        s.insert(tokens: toks(10), payload: "system", bytes: 60, kind: .system)
        s.insert(tokens: toks(20), payload: "b20", bytes: 60, kind: .boundary)
        s.insert(tokens: toks(30), payload: "b30", bytes: 60, kind: .boundary)
        s.prune(keepingPrefixesOf: toks(50))
        #expect(Set(s.entries.map(\.payload)) == ["system", "b30"])   // still over cap, but nothing else is evictable
    }
}

@Suite("PrefillPlan")
struct PrefillPlanTests {

    @Test("chunks cover the range exactly and end on every stop")
    func alignment() {
        let ranges = PrefillPlan.chunks(from: 0, to: 1300, chunk: 512, stops: [100, 700])
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == 1300)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(ranges.allSatisfy { $0.count <= 512 && !$0.isEmpty })
        let ends = Set(ranges.map(\.upperBound))
        #expect(ends.contains(100) && ends.contains(700))
    }

    @Test("stops at or before the restored offset are ignored; empty range yields no chunks")
    func edges() {
        #expect(PrefillPlan.chunks(from: 500, to: 500, chunk: 512, stops: [100]).isEmpty)
        let r = PrefillPlan.chunks(from: 300, to: 400, chunk: 512, stops: [100, 300, 400])
        #expect(r == [300..<400])
    }

    @Test("snapshotStops keeps only boundaries beyond the restore point and inside the prefill")
    func stops() {
        #expect(PrefillPlan.snapshotStops(boundaries: [50, 200, 400, 900], restoredUpTo: 200, prefillEnd: 600) == [400])
    }
}

@Suite("PromptSnapshotStore retain")
struct PromptSnapshotStoreRetainTests {

    private func toks(_ n: Int) -> [Int32] { (0..<n).map { Int32($0) } }

    @Test("keeps the longest prefixes that fit and always the system entry")
    func keepsLongestWithinLimit() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(10), payload: "system", bytes: 5, kind: .system)
        s.insert(tokens: toks(30), payload: "turn1", bytes: 40, kind: .boundary)
        s.insert(tokens: toks(50), payload: "turn2", bytes: 40, kind: .boundary)
        s.insert(tokens: toks(70), payload: "turn3", bytes: 40, kind: .boundary)
        s.retain(upToBytes: 100)
        #expect(Set(s.entries.map(\.payload)) == ["system", "turn3", "turn2"])
        #expect(s.bestMatch(for: toks(80), maxLength: 79)?.payload == "turn3")
    }

    @Test("an entry bigger than the limit is dropped, the system entry stays")
    func dropsOversize() {
        var s = PromptSnapshotStore<String>()
        s.insert(tokens: toks(10), payload: "system", bytes: 5, kind: .system)
        s.insert(tokens: toks(90), payload: "huge", bytes: 500, kind: .boundary)
        s.retain(upToBytes: 100)
        #expect(s.entries.map(\.payload) == ["system"])
    }
}
