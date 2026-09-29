import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("PromptEngineer")
struct PromptEngineerTests {

    @Test("classifies generate intent")
    func classifyGenerate() {
        #expect(PromptEngineer.classify("create a new SwiftUI view for settings") == .generate)
        #expect(PromptEngineer.classify("implement the login feature") == .generate)
    }

    @Test("classifies debug intent")
    func classifyDebug() {
        #expect(PromptEngineer.classify("fix the crash in AppCoordinator") == .debug)
        #expect(PromptEngineer.classify("this error won't go away") == .debug)
    }

    @Test("classifies refactor intent")
    func classifyRefactor() {
        #expect(PromptEngineer.classify("refactor the buildMessages function") == .refactor)
        #expect(PromptEngineer.classify("simplify this code") == .refactor)
    }

    @Test("classifies explain intent")
    func classifyExplain() {
        #expect(PromptEngineer.classify("explain how the correction loop works") == .explain)
        #expect(PromptEngineer.classify("what does IndexingPipeline do") == .explain)
    }

    @Test("classifies test intent")
    func classifyTest() {
        #expect(PromptEngineer.classify("write unit tests for VectorStore") == .test)
        #expect(PromptEngineer.classify("add test coverage for this function") == .test)
    }

    @Test("classifies review intent")
    func classifyReview() {
        #expect(PromptEngineer.classify("review this implementation") == .review)
        #expect(PromptEngineer.classify("check if this is correct") == .review)
    }

    @Test("falls back to general for ambiguous prompt")
    func classifyGeneral() {
        #expect(PromptEngineer.classify("hello") == .general)
        #expect(PromptEngineer.classify("") == .general)
    }

    @Test("engineer injects system addendum")
    func engineerSystemAddendum() {
        let messages = [
            Message(role: .system, content: "Base prompt."),
            Message(role: .user, content: "fix the crash"),
        ]
        let result = PromptEngineer.engineer(messages: messages, intent: .debug)
        let sys = result.first(where: { $0.role == .system })!
        #expect(sys.content.contains("Base prompt."))
        #expect(sys.content.contains("root cause"))
    }

    @Test("engineer adds task framing to user message")
    func engineerUserFraming() {
        let messages = [
            Message(role: .system, content: "Base."),
            Message(role: .user, content: "create a model"),
        ]
        let result = PromptEngineer.engineer(messages: messages, intent: .generate)
        let user = result.last(where: { $0.role == .user })!
        #expect(user.content.hasPrefix("[Task: generate]"))
        #expect(user.content.contains("create a model"))
    }

    @Test("engineer is a no-op on empty array")
    func engineerEmpty() {
        #expect(PromptEngineer.engineer(messages: [], intent: .general).isEmpty)
    }

    @Test("general intent adds no framing prefix")
    func engineerGeneralNoFraming() {
        let messages = [
            Message(role: .system, content: "Base."),
            Message(role: .user, content: "hello"),
        ]
        let result = PromptEngineer.engineer(messages: messages, intent: .general)
        let user = result.last(where: { $0.role == .user })!
        #expect(user.content == "hello")
    }
}
