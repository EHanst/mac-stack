import Testing
import Foundation
@testable import StackCore
@testable import VibeCockpitCore

@Suite("RetrievalBudget")
struct RetrievalBudgetTests {

    private func chunk(_ name: String, lines: Int) -> RetrievalBudget.Chunk {
        .init(fileName: name, kind: "struct", content: (0..<lines).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
    }

    @Test("everything is included when it fits, best hit first")
    func fits() throws {
        let out = try #require(RetrievalBudget.render([chunk("A.swift", lines: 5), chunk("B.swift", lines: 5)], maxTokens: 2_000))
        #expect(out.hasPrefix(RetrievalBudget.header))
        #expect(out.range(of: "A.swift")!.lowerBound < out.range(of: "B.swift")!.lowerBound)
        #expect(!out.contains("cut to fit"))
    }

    @Test("a chunk that doesn't fit is cut at a line boundary; later hits are dropped")
    func cuts() throws {
        let big = chunk("Big.swift", lines: 2_000)                     // ~ 12k tokens
        let out = try #require(RetrievalBudget.render([big, chunk("After.swift", lines: 3)], maxTokens: 800))
        #expect(out.contains("cut to fit"))
        #expect(!out.contains("After.swift"))
        #expect(TokenCalibration().tokens(chars: out.count) <= 800)
        // whole lines only: the last kept line is complete
        let kept = out.components(separatedBy: "\n").filter { $0.hasPrefix("let value") }
        #expect(kept.allSatisfy { $0.hasSuffix("= \(kept.firstIndex(of: $0)!)") })
    }

    @Test("with too little room nothing is included")
    func none() {
        #expect(RetrievalBudget.render([chunk("A.swift", lines: 2_000)], maxTokens: 100) == nil)
        #expect(RetrievalBudget.render([], maxTokens: 5_000) == nil)
    }

    @Test("room is a quarter of the ceiling, and shrinks as the conversation fills it")
    func room() {
        #expect(RetrievalBudget.maxTokens(ceiling: 10_000, currentPromptTokens: 0) == 2_500)
        #expect(RetrievalBudget.maxTokens(ceiling: 10_000, currentPromptTokens: 6_000) == 1_800)   // 7,800 trigger − 6,000
        #expect(RetrievalBudget.maxTokens(ceiling: 10_000, currentPromptTokens: 9_000) == 0)
        #expect(RetrievalBudget.maxTokens(ceiling: nil, currentPromptTokens: 50_000) == RetrievalBudget.cloudMaxTokens)
    }

    @Test("the retrieved block is found inside a stored user turn, and only there")
    func span() throws {
        let turn = PromptEngineer.augmentUserTurn("fix the crash", intent: .debug, ragContext: "\(RetrievalBudget.header)\n// A.swift — struct\nlet x = 1\n", recipe: "")
        let range = try #require(RetrievalBudget.span(in: turn))
        #expect(turn[range].hasPrefix(RetrievalBudget.header))
        #expect(turn[range].contains("let x = 1"))
        #expect(!turn[range].contains("fix the crash"))
        #expect(RetrievalBudget.span(in: "no retrieval here") == nil)
    }
}

@Suite("Compaction of retrieved code")
struct RetrievedCodeCompactionTests {

    private func ragTurn(_ n: Int, codeLines: Int = 120) -> Message {
        let code = (0..<codeLines).map { "let v\($0) = \($0)" }.joined(separator: "\n")
        return Message(role: .user, content: PromptEngineer.augmentUserTurn(
            "question \(n)", intent: .general, ragContext: "\(RetrievalBudget.header)\n// F\(n).swift — struct\n\(code)\n", recipe: ""))
    }

    private func ledger(turns: Int) -> PromptLedger {
        var l = PromptLedger()
        l.begin(system: "SYS")
        for n in 0..<turns {
            l.appendUserTurn(ragTurn(n).content)
            l.appendAssistant("answer \(n)")
        }
        return l
    }

    @Test("old user turns report their retrieved code as clearable; the request text is not")
    func items() {
        let l = ledger(turns: 3)
        let items = l.compactionItems()
        #expect(items[0].elidableTokens == 0)                            // system
        #expect(items[1].elidableTokens > 200)                           // user turn with code
        #expect(items[1].elidableTokens < items[1].tokens)
        #expect(items[2].elidableTokens == 0)                            // assistant
    }

    @Test("eliding replaces only the retrieved block; the request and turn count stay")
    func elideKeepsRequest() {
        var l = ledger(turns: 3)
        let freed = l.elide([1])
        #expect(freed > 200)
        #expect(l.messages[1].content.contains(RetrievalBudget.stub))
        #expect(l.messages[1].content.contains("User request: question 0") || l.messages[1].content.contains("question 0"))
        #expect(!l.messages[1].content.contains("let v50"))
        #expect(l.messages[3].content.contains("let v50"))               // other turns untouched
        #expect(l.userTurns == 3)
        #expect(l.messages[1].role == .user)
    }

    @Test("the planner clears retrieved code from old turns before summarizing anything")
    func plannerUsesIt() {
        let l = ledger(turns: 10)
        let items = l.compactionItems()
        let total = items.reduce(0) { $0 + $1.tokens }
        let plan = CompactionPlanner().plan(items: items, maxPromptTokens: Int(Double(total) / 0.85))
        #expect(!plan.elide.isEmpty)
        #expect(plan.elide.allSatisfy { items[$0].role == .user })
        #expect(plan.tokensAfter < plan.tokensBefore)
    }
}
