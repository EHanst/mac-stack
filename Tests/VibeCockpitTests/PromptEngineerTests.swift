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

@Suite("PromptEngineer recipes and whole-word matching")
struct PromptEngineerRecipeTests {

    @Test("keywords match whole words, not fragments")
    func wholeWords() {
        #expect(PromptEngineer.classify("what is the address of the server") != .generate)
        #expect(PromptEngineer.classify("remove the old cache") != .refactor)
        #expect(PromptEngineer.classify("this is an evaluation of options") == .general)
    }

    @Test("plain inflections still match")
    func inflections() {
        #expect(PromptEngineer.classify("I keep hitting crashes") == .debug)
        #expect(PromptEngineer.classify("we are creating a settings screen") == .generate)
        #expect(PromptEngineer.classify("write some tests") == .test)
    }

    @Test("no recipe given: the built-in guidance is used")
    func defaultRecipe() {
        let turn = PromptEngineer.augmentUserTurn("fix it", intent: .debug, ragContext: nil)
        #expect(turn.hasPrefix(BuiltInPrompts.recipeText(for: "debug")))
        #expect(turn.hasSuffix("[Task: debug]\nfix it"))
    }

    @Test("an edited recipe replaces the built-in guidance")
    func customRecipe() {
        let turn = PromptEngineer.augmentUserTurn("fix it", intent: .debug, ragContext: nil, recipe: "Be brief.")
        #expect(turn == "Be brief.\n\n[Task: debug]\nfix it")
    }

    @Test("a switched-off recipe adds no guidance and no stray blank lines")
    func offRecipe() {
        #expect(PromptEngineer.augmentUserTurn("fix it", intent: .debug, ragContext: nil, recipe: "") == "[Task: debug]\nfix it")
        #expect(PromptEngineer.augmentUserTurn("hello", intent: .general, ragContext: nil, recipe: "") == "hello")
    }

    @Test("intent keys line up with the library's recipe keys")
    func keys() {
        let all: [PromptEngineer.Intent] = [.generate, .debug, .refactor, .explain, .test, .review, .general]
        #expect(Set(all.map(\.rawValue)) == Set(BuiltInPrompts.intents))
    }
}

@Suite("Kokoro system prompt")
struct IdentityPromptTests {
    private let prompt = AppServices.systemPrompt(workspaceRoot: "/w/app", snapshotsAvailable: true)

    @Test("stays short: it is sent with every conversation and eats local context")
    func short() {
        // ~4 characters per token for English prose: 1600 characters is about 400 tokens.
        #expect(prompt.count <= 1600)
    }

    @Test("is a pure function of its inputs, so the prompt is identical every turn (cache-safe)")
    func deterministic() {
        #expect(prompt == AppServices.systemPrompt(workspaceRoot: "/w/app", snapshotsAvailable: true))
    }

    @Test("follows its own principles: reference first, facts next, instructions last")
    func order() {
        let rules = prompt.range(of: PromptPrinciples.rules)!, facts = prompt.range(of: "Workspace root: /w/app")!
        let goal = prompt.range(of: "Goal:")!, untrusted = prompt.range(of: "<untrusted>")!
        #expect(rules.upperBound <= facts.lowerBound && facts.upperBound <= goal.lowerBound && goal.upperBound <= untrusted.lowerBound)
        #expect(prompt.contains("A good reply"))
    }

    @Test("omits facts it does not have")
    func optionalFacts() {
        let bare = AppServices.systemPrompt(workspaceRoot: nil, snapshotsAvailable: false)
        #expect(!bare.contains("Workspace root") && !bare.contains("snapshots"))
    }

    @Test("says what the app is, keeps the correctness rules and has no persona")
    func content() {
        #expect(prompt.contains("Kokoro") && prompt.contains("prompts for frontier AI models"))
        #expect(prompt.contains("unspecified") && prompt.contains("small and focused"))
        for word in ["personality", "persona", "Address the user", "senpai", "sugoi", "playful", "VibeCockpit"] {
            #expect(!prompt.localizedCaseInsensitiveContains(word))
        }
    }
}

@Suite("Prompt principles")
struct PromptPrinciplesTests {
    @Test("the shared block stays within its word budget")
    func budget() {
        let words = PromptPrinciples.rules.split(whereSeparator: \.isWhitespace).count
        #expect(words <= PromptPrinciples.wordLimit)
    }

    @Test("it covers goal, constraints, naming, data-first, output format and no invention")
    func coverage() {
        let r = PromptPrinciples.rules.lowercased()
        for key in ["one task", "done looks like", "never invent", "non-goals", "data", "output format", "number the steps"] {
            #expect(r.contains(key), "missing \(key)")
        }
    }
}
