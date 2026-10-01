import Testing
import Foundation
@testable import StackCore

@Suite("CompactionPlanner")
struct CompactionPlannerTests {

    private typealias Item = CompactionPlanner.Item

    private func turn(_ user: Int = 100, tool: Int? = nil, reply: Int = 100) -> [Item] {
        var items = [Item(role: .user, tokens: user)]
        if let tool { items.append(Item(role: .tool, tokens: tool)) }
        items.append(Item(role: .assistant, tokens: reply))
        return items
    }

    private func chat(turns: Int, tool: Int? = 2_000) -> [Item] {
        [Item(role: .system, tokens: 500)] + (0..<turns).flatMap { _ in turn(tool: tool) }
    }

    @Test("under the trigger nothing changes")
    func underTrigger() {
        let items = chat(turns: 2, tool: 200)
        let plan = CompactionPlanner().plan(items: items, maxPromptTokens: 10_000)
        #expect(plan.outcome == .none)
        #expect(plan.elide.isEmpty && plan.summarize == nil)
        #expect(plan.tokensBefore == plan.tokensAfter)
    }

    @Test("old tool output is stubbed oldest-first, only as far as the target needs")
    func elidesOldestFirst() {
        let items = chat(turns: 14)                      // 500 + 14 × 2,200 = 31,300
        let plan = CompactionPlanner().plan(items: items, maxPromptTokens: 38_000)
        #expect(plan.outcome == .compact)
        #expect(plan.elide == plan.elide.sorted())
        #expect(plan.tokensAfter <= 13_300)
        #expect(plan.tokensAfter > 13_300 - 2_200)       // stopped as soon as the target was met
        #expect(plan.elide.first == 2)                   // first turn's tool message
    }

    @Test("the recent turns, the system prompt and pinned messages are never touched")
    func protectedMessages() {
        var items = chat(turns: 14)
        items[2].isPinned = true                          // first turn's tool output
        let plan = CompactionPlanner(keepRecentTurns: 4, minKeepRecentTurns: 4).plan(items: items, maxPromptTokens: 38_000)
        #expect(!plan.elide.contains(0))
        #expect(!plan.elide.contains(2))
        // Turn 11 starts at index 1 + 10×3 = 31 and is the protected window's first message.
        #expect(plan.elide.allSatisfy { $0 < 31 })
    }

    @Test("small tool output is not worth a stub")
    func skipsSmallOutput() {
        let items = chat(turns: 40, tool: 100)
        let plan = CompactionPlanner().plan(items: items, maxPromptTokens: 10_000)
        #expect(plan.elide.isEmpty)
        #expect(plan.outcome == .insufficient(hardFit: false))
    }

    @Test("when elision is not enough and summarizing is off, the plan says it is insufficient")
    func insufficientWithoutSummary() {
        let items = chat(turns: 30, tool: nil)           // no tool output to elide
        let plan = CompactionPlanner().plan(items: items, maxPromptTokens: 8_000)   // 6,500 fits, target 3,200 does not
        #expect(plan.outcome == .insufficient(hardFit: true))
        #expect(plan.summarize == nil)
    }

    @Test("with summarizing allowed, the oldest run is replaced and the target is reached")
    func summarizes() {
        let items = chat(turns: 30, tool: nil)           // 500 + 30 × 200 = 6,500
        let plan = CompactionPlanner(allowSummarize: true).plan(items: items, maxPromptTokens: 8_000)
        #expect(plan.outcome == .compact)
        let run = try! #require(plan.summarize)
        #expect(run.lowerBound == 1)
        #expect(items[run.lowerBound].role == .user)
        #expect(plan.tokensAfter <= 3_200)
    }

    @Test("a summary of untrusted messages is itself untrusted")
    func taintCarries() {
        var items = chat(turns: 30, tool: nil)
        items[5].isUntrusted = true
        let plan = CompactionPlanner(allowSummarize: true).plan(items: items, maxPromptTokens: 8_000)
        #expect(plan.summarize != nil)
        #expect(plan.summaryIsUntrusted)
        var clean = chat(turns: 30, tool: nil)
        clean[5].isUntrusted = false
        #expect(!CompactionPlanner(allowSummarize: true).plan(items: clean, maxPromptTokens: 8_000).summaryIsUntrusted)
    }

    @Test("a pinned message ends the summarized run")
    func pinSplitsRun() {
        var items = chat(turns: 30, tool: nil)
        items[10].isPinned = true
        let plan = CompactionPlanner(allowSummarize: true).plan(items: items, maxPromptTokens: 8_000)
        let run = try! #require(plan.summarize)
        #expect(!run.contains(10))
    }

    @Test("planning is deterministic")
    func deterministic() {
        let items = chat(turns: 12)
        let p = CompactionPlanner()
        #expect(p.plan(items: items, maxPromptTokens: 20_000) == p.plan(items: items, maxPromptTokens: 20_000))
    }

    @Test("a tighter ceiling from memory pressure compacts sooner")
    func tighterCeiling() {
        let items = chat(turns: 14)
        let p = CompactionPlanner()
        #expect(p.plan(items: items, maxPromptTokens: 60_000).outcome == .none)
        #expect(p.plan(items: items, maxPromptTokens: 38_000).outcome == .compact)
    }
}

@Suite("CompactionPlanner adaptive window")
struct CompactionPlannerWindowTests {

    private func chat(turns: Int, tool: Int) -> [CompactionPlanner.Item] {
        [.init(role: .system, tokens: 500)] + (0..<turns).flatMap { _ in
            [CompactionPlanner.Item(role: .user, tokens: 100), .init(role: .tool, tokens: tool), .init(role: .assistant, tokens: 100)]
        }
    }

    @Test("a window that can't reach the target shrinks until it can")
    func windowShrinks() {
        // 9 turns × 1,200 + 500 = 11,300; ceiling 13,700 → trigger 10,686, target 4,795.
        // After clearing old tool output: 4 recent turns → 6,450, 3 → 5,480, 2 → 4,510.
        let items = chat(turns: 9, tool: 1_000)
        let wide = CompactionPlanner(minKeepRecentTurns: 4).plan(items: items, maxPromptTokens: 13_700)
        let adaptive = CompactionPlanner().plan(items: items, maxPromptTokens: 13_700)
        #expect(wide.outcome != .compact)
        #expect(adaptive.outcome == .compact)
        #expect(adaptive.tokensAfter <= 4_795)
        // The two most recent turns (from index 1 + 7×3 = 22) stay untouched.
        #expect(adaptive.elide.allSatisfy { $0 < 22 })
    }

    @Test("with room to spare the full window is kept")
    func fullWindowKept() {
        let items = chat(turns: 8, tool: 200)               // 500 + 8 × 400 = 3,700
        let plan = CompactionPlanner().plan(items: items, maxPromptTokens: 4_400)   // trigger 3,432, target 1,540
        #expect(plan.elide.isEmpty)                          // 200-token results are below minElideTokens
    }
}

@Suite("TokenCalibration")
struct TokenCalibrationTests {

    @Test("starts at the pessimistic 2.5 and learns from the model's counts")
    func learns() {
        var c = TokenCalibration()
        #expect(c.charsPerToken == 2.5)
        c.observe(chars: 24_000, promptTokens: 6_000)     // 4.0
        c.observe(chars: 24_000, promptTokens: 6_000)
        #expect(c.charsPerToken == 4.0)
        #expect(c.tokens(chars: 8_000) == 2_000)
    }

    @Test("never above 4.0 or below 2.5, and tiny prompts are ignored")
    func clamps() {
        var c = TokenCalibration()
        c.observe(chars: 100_000, promptTokens: 1_000)    // 100 chars/token → clamped to 4.0
        c.observe(chars: 100_000, promptTokens: 1_000)
        #expect(c.charsPerToken == 4.0)
        c.observe(chars: 10, promptTokens: 5)              // below the minimum sample
        #expect(c.charsPerToken == 4.0)
        c.observe(chars: 1_000, promptTokens: 1_000)       // 1.0 → clamped to 2.5
        #expect(c.charsPerToken == 2.5)
    }

    @Test("one prose-heavy turn can't make a code-heavy stretch look cheap")
    func usesLowerOfLastTwo() {
        var c = TokenCalibration()
        c.observe(chars: 8_000, promptTokens: 2_500)       // 3.2
        c.observe(chars: 16_000, promptTokens: 4_000)      // 4.0
        #expect(c.charsPerToken == 3.2)
    }
}
