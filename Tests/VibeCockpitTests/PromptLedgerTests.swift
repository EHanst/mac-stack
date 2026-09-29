import Testing
import Foundation
@testable import VibeCockpitCore

@Suite("PromptLedger")
struct PromptLedgerTests {

    private func rendered(_ l: PromptLedger) -> String { ChatPromptRenderer.render(l.messages).text }

    @Test("earlier messages never change as the conversation grows")
    func appendOnly() {
        var l = PromptLedger()
        l.begin(system: "SYS")
        l.appendUserTurn("turn one")
        let afterTurn1 = l.messages
        l.appendAssistant("answer one")
        l.appendToolResult(id: "t1", content: "file contents")
        l.appendAssistant("answer two")
        l.appendUserTurn("turn two")
        #expect(Array(l.messages.prefix(afterTurn1.count)).map(\.content) == afterTurn1.map(\.content))
        #expect(l.userTurns == 2)
    }

    @Test("previous request's full prompt is a strict text prefix of the next request's")
    func promptPrefixProperty() {
        var l = PromptLedger()
        l.begin(system: "SYS")
        l.appendUserTurn("hello")
        let firstPrompt = rendered(l)                 // includes the generation prompt
        l.appendAssistant("hi there")
        l.appendUserTurn("second question")
        #expect(rendered(l).hasPrefix(firstPrompt))
    }

    @Test("empty assistant output is not recorded")
    func emptyAssistantIgnored() {
        var l = PromptLedger()
        l.begin(system: "SYS")
        l.appendUserTurn("q")
        l.appendAssistant("")
        #expect(l.messages.count == 2)
    }

    @Test("begin seeds prior history verbatim and counts its user turns")
    func seeding() {
        var l = PromptLedger()
        l.begin(system: "SYS", prior: [Message(role: .user, content: "a"),
                                       Message(role: .assistant, content: "b")])
        #expect(l.userTurns == 1)
        l.appendUserTurn("c")
        #expect(l.messages.map(\.content) == ["SYS", "a", "b", "c"])
    }

    @Test("trim drops whole oldest turns, keeps system + latest turn, and is stable afterwards")
    func trimming() {
        var l = PromptLedger()
        l.begin(system: "SYS")
        for i in 0..<5 {
            l.appendUserTurn("user \(i) " + String(repeating: "x", count: 100))
            l.appendAssistant("assistant \(i) " + String(repeating: "y", count: 100))
        }
        l.appendUserTurn("latest")
        let didTrim = l.trim(toCharacterBudget: 500)
        #expect(didTrim)
        #expect(l.messages.first?.role == .system)
        #expect(l.messages.last?.content == "latest")
        #expect(l.messages.dropFirst().first?.role == .user)      // no orphaned assistant at the front
        let stable = l.messages.map(\.content)
        let trimAgain = l.trim(toCharacterBudget: 500)             // already fits: nothing changes
        #expect(!trimAgain)
        #expect(l.messages.map(\.content) == stable)
    }

    @Test("trim never removes the only turn")
    func trimKeepsLastTurn() {
        var l = PromptLedger()
        l.begin(system: "SYS")
        l.appendUserTurn(String(repeating: "z", count: 1000))
        let didTrim = l.trim(toCharacterBudget: 10)
        #expect(!didTrim)
        #expect(l.messages.count == 2)
    }
}

@Suite("ChatPromptRenderer")
struct ChatPromptRendererTests {

    @Test("one segment per message, each ending at a message boundary")
    func segments() {
        let r = ChatPromptRenderer.render([Message(role: .system, content: "s"),
                                           Message(role: .user, content: "u")])
        #expect(r.segments.count == 2)
        #expect(r.segments.allSatisfy { $0.hasSuffix("<|im_end|>\n") })
        #expect(r.generation == "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(r.text == r.segments.joined() + r.generation)
    }

    @Test("assistant history renders as generation prompt + content + end marker")
    func assistantMatchesGeneration() {
        let seg = ChatPromptRenderer.render([Message(role: .assistant, content: "reply")]).segments[0]
        #expect(seg == ChatPromptRenderer.generationPrompt + "reply<|im_end|>\n")
    }
}

@Suite("PromptEngineer.augmentUserTurn")
struct AugmentUserTurnTests {

    @Test("is deterministic and contains guidance, framing, RAG and the request")
    func composition() {
        let a = PromptEngineer.augmentUserTurn("fix the crash", intent: .debug, ragContext: "Relevant code:\nfoo()")
        let b = PromptEngineer.augmentUserTurn("fix the crash", intent: .debug, ragContext: "Relevant code:\nfoo()")
        #expect(a == b)
        #expect(a.contains("When debugging"))
        #expect(a.contains("[Task: debug]"))
        #expect(a.contains("Relevant code:\nfoo()"))
        #expect(a.hasSuffix("User request: fix the crash"))
    }

    @Test("without RAG the request is used as-is after the framing")
    func noRag() {
        let s = PromptEngineer.augmentUserTurn("explain this", intent: .explain, ragContext: nil)
        #expect(s.hasSuffix("[Task: explain]\nexplain this"))
    }
}
