import Testing
import Foundation
@testable import StackCore

@Suite("PromptLint and profiles")
struct PromptLintTests {

    private func rules(_ text: String, _ ctx: PromptLint.Context = .init()) -> Set<PromptLint.Finding.Rule> {
        Set(PromptLint.check(text, context: ctx).map(\.rule))
    }

    @Test("empty draft has no findings")
    func empty() { #expect(rules("   ").isEmpty) }

    @Test("a two-word draft is too short")
    func short() { #expect(rules("fix it").contains(.tooShort)) }

    @Test("vague pronoun with no file is flagged; naming the file clears it")
    func target() {
        #expect(rules("please make this faster and cleaner").contains(.noTarget))
        #expect(!rules("please make this faster in Sources/App/Loader.swift").contains(.noTarget))
        #expect(!rules("please make `load()` faster and cleaner").contains(.noTarget))
    }

    @Test("debug, generate, refactor and test ask for a success criterion")
    func criterion() {
        let ctx = PromptLint.Context(intent: "debug")
        #expect(rules("the settings screen crashes on launch every time", ctx).contains(.noSuccessCriterion))
        #expect(!rules("the settings screen crashes on launch, it should open normally", ctx).contains(.noSuccessCriterion))
        #expect(!rules("the settings screen crashes on launch every time", .init(intent: "explain")).contains(.noSuccessCriterion))
        for intent in ["refactor", "test"] {
            #expect(rules("tidy up the settings screen loader code", .init(intent: intent)).contains(.noSuccessCriterion))
            #expect(!rules("tidy up the settings screen loader, done when the tests pass", .init(intent: intent)).contains(.noSuccessCriterion))
        }
    }

    @Test("a bare error message gets a suggested question")
    func errorOnly() {
        let found = PromptLint.check("error: cannot find 'Foo' in scope", context: .init())
        #expect(found.contains { $0.rule == .errorWithoutQuestion && $0.suggestion != nil })
        #expect(!rules("error: cannot find 'Foo' in scope\nwhy does this happen after I renamed the type?").contains(.errorWithoutQuestion))
    }

    @Test("many questions are flagged as several requests")
    func multiple() { #expect(rules("what is this? why? how do I fix it? and who owns it?").contains(.multipleAsks)) }

    @Test("length limit comes from the model profile")
    func tooLong() {
        let long = String(repeating: "word ", count: 2_000)
        #expect(rules(long, .init(maxTokens: ModelPromptProfile.localSmall.maxUsefulTokens)).contains(.tooLong))
        #expect(!rules(long, .init(maxTokens: ModelPromptProfile.claude.maxUsefulTokens)).contains(.tooLong))
    }

    @Test("profiles are chosen from the provider id")
    func profiles() {
        #expect(ModelPromptProfile.profile(forProviderID: "local:Ternary-Bonsai-27B").family == "local")
        #expect(ModelPromptProfile.profile(forProviderID: "anthropic").family == "claude")
        #expect(ModelPromptProfile.profile(forProviderID: "openai-gpt-5").family == "gpt")
        #expect(ModelPromptProfile.profile(forProviderID: "openrouter").family == "generic")
        #expect(ModelPromptProfile.profile(forProviderID: nil).family == "generic")
    }

    @Test("Claude flags unbalanced XML tags")
    func claudeUnbalancedXML() {
        let c = PromptLint.Context(modelFamily: "claude")
        #expect(PromptLint.check("Fix this. <task>do the thing", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Fix this. <task>do the thing</task>", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Return nil when a < b in Parser.swift", context: c).contains { $0.rule == .unbalancedXML })
    }

    @Test("Claude does not flag self-closing tags")
    func claudeSelfClosingTags() {
        let c = PromptLint.Context(modelFamily: "claude")
        #expect(!PromptLint.check("Add a line break <br/> here", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Use <tag/> for self-closing", context: c).contains { $0.rule == .unbalancedXML })
    }

    @Test("Claude does not flag HTML void tags")
    func claudeHTMLVoidTags() {
        let c = PromptLint.Context(modelFamily: "claude")
        #expect(!PromptLint.check("Add a <br> break here", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Include <hr> separator", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Add <img src='x'> image", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Use <input type='text'> field", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Add <meta name='x'> tag", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Link <link rel='x'> here", context: c).contains { $0.rule == .unbalancedXML })
    }

    @Test("Claude ignores text inside fenced code blocks")
    func claudeTagsInFences() {
        let c = PromptLint.Context(modelFamily: "claude")
        #expect(!PromptLint.check("Example:\n```\n<task>incomplete\n```", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Inline `<tag>` code is ignored", context: c).contains { $0.rule == .unbalancedXML })
    }

    @Test("Claude compares tag names case-insensitively")
    func claudeTagCaseInsensitive() {
        let c = PromptLint.Context(modelFamily: "claude")
        #expect(!PromptLint.check("Fix this. <Task>do the thing</task>", context: c).contains { $0.rule == .unbalancedXML })
        #expect(!PromptLint.check("Fix this. <TASK>do the thing</Task>", context: c).contains { $0.rule == .unbalancedXML })
    }

    @Test("Claude still flags unmatched closing tags")
    func claudeUnmatchedClosingTags() {
        let c = PromptLint.Context(modelFamily: "claude")
        #expect(PromptLint.check("Fix this. </x>", context: c).contains { $0.rule == .unbalancedXML })
        #expect(PromptLint.check("Fix this. <task>thing</other>", context: c).contains { $0.rule == .unbalancedXML })
    }

    @Test("Reasoning flags chain-of-thought instructions")
    func reasoningFlagsChainOfThought() {
        let c = PromptLint.Context(modelFamily: "reasoning")
        #expect(PromptLint.check("Fix the parser. Think step by step.", context: c).contains { $0.rule == .chainOfThought })
        #expect(!PromptLint.check("Fix the parser in Parser.swift.", context: c).contains { $0.rule == .chainOfThought })
    }

    @Test("Reasoning ignores chain-of-thought in quotes")
    func reasoningIgnoresQuotedChainOfThought() {
        let c = PromptLint.Context(modelFamily: "reasoning")
        #expect(!PromptLint.check("Don't say \"think step by step\" in your output.", context: c).contains { $0.rule == .chainOfThought })
        #expect(!PromptLint.check("Fix the parser. It says 'step by step' in the docs.", context: c).contains { $0.rule == .chainOfThought })
    }

    @Test("Reasoning ignores chain-of-thought in backticks")
    func reasoningIgnoresBracktickChainOfThought() {
        let c = PromptLint.Context(modelFamily: "reasoning")
        #expect(!PromptLint.check("Don't output `step by step` analysis.", context: c).contains { $0.rule == .chainOfThought })
        #expect(!PromptLint.check("Check that the output doesn't say `think aloud`.", context: c).contains { $0.rule == .chainOfThought })
    }

    @Test("Reasoning ignores negated chain-of-thought forms")
    func reasoningIgnoresNegatedChainOfThought() {
        let c = PromptLint.Context(modelFamily: "reasoning")
        #expect(!PromptLint.check("Do not think step by step.", context: c).contains { $0.rule == .chainOfThought })
        #expect(!PromptLint.check("Don't show your reasoning.", context: c).contains { $0.rule == .chainOfThought })
        #expect(!PromptLint.check("Never use chain of thought.", context: c).contains { $0.rule == .chainOfThought })
        #expect(!PromptLint.check("Don't think aloud.", context: c).contains { $0.rule == .chainOfThought })
    }

    @Test("Reasoning ignores chain-of-thought in fences")
    func reasoningIgnoresFencedChainOfThought() {
        let c = PromptLint.Context(modelFamily: "reasoning")
        #expect(!PromptLint.check("Example:\n```\nThink step by step.\n```", context: c).contains { $0.rule == .chainOfThought })
    }

    @Test("GPT requires goal first")
    func gptGoalFirst() {
        let c = PromptLint.Context(modelFamily: "gpt")
        #expect(PromptLint.check("- return nil\n- add tests for Parser.swift", context: c).contains { $0.rule == .goalNotFirst })
        #expect(!PromptLint.check("Add tests for Parser.swift.\n- return nil", context: c).contains { $0.rule == .goalNotFirst })
    }

    @Test("startsWithGoal trims leading whitespace")
    func startsWithGoalTrimsWhitespace() {
        let c = PromptLint.Context(modelFamily: "gpt")
        #expect(!PromptLint.check("   Add tests for Parser.swift.\n- return nil", context: c).contains { $0.rule == .goalNotFirst })
        #expect(!PromptLint.check("\t\tFix the parser", context: c).contains { $0.rule == .goalNotFirst })
    }

    @Test("startsWithGoal treats numbered items as NOT a goal")
    func startsWithGoalNumberedItems() {
        let c = PromptLint.Context(modelFamily: "gpt")
        #expect(PromptLint.check("1. Return nil\n2. Add tests", context: c).contains { $0.rule == .goalNotFirst })
        #expect(PromptLint.check("2) Add tests", context: c).contains { $0.rule == .goalNotFirst })
    }

    @Test("startsWithGoal treats indented bullets as NOT a goal")
    func startsWithGoalIndentedBullets() {
        let c = PromptLint.Context(modelFamily: "gpt")
        #expect(PromptLint.check("   - return nil\n   - add tests", context: c).contains { $0.rule == .goalNotFirst })
        #expect(PromptLint.check("  * item 1", context: c).contains { $0.rule == .goalNotFirst })
        #expect(PromptLint.check("\t+ item", context: c).contains { $0.rule == .goalNotFirst })
    }

    @Test("startsWithGoal treats fences and blockquotes and headings as NOT a goal")
    func startsWithGoalOtherMarkers() {
        let c = PromptLint.Context(modelFamily: "gpt")
        #expect(PromptLint.check("```\ncode here", context: c).contains { $0.rule == .goalNotFirst })
        #expect(PromptLint.check("> quoted text", context: c).contains { $0.rule == .goalNotFirst })
        #expect(PromptLint.check("# Heading", context: c).contains { $0.rule == .goalNotFirst })
    }

    @Test("startsWithGoal treats single backtick followed by prose as a goal")
    func startsWithGoalSingleBacktick() {
        let c = PromptLint.Context(modelFamily: "gpt")
        #expect(!PromptLint.check("`loadItems` should return nil.", context: c).contains { $0.rule == .goalNotFirst })
        #expect(!PromptLint.check("`myFunc()` must handle errors", context: c).contains { $0.rule == .goalNotFirst })
    }

    @Test("family-specific rules don't fire without a family")
    func noFamilyRulesWithoutFamily() {
        #expect(PromptLint.check("Think step by step <a>", context: .init()).allSatisfy {
            ![.unbalancedXML, .chainOfThought, .goalNotFirst].contains($0.rule)
        })
    }

    @Test("isAlreadyClear needs length, literals, a success check and no vague words")
    func alreadyClear() {
        let clear = "Rename the property `title` to `heading` on `Note` in Sources/Model/Note.swift and update every call site. Do not change behaviour. Build must pass."
        #expect(PromptLint.isAlreadyClear(clear))
        #expect(!PromptLint.isAlreadyClear("make the app faster"))
        #expect(!PromptLint.isAlreadyClear("fix the crash in `loadItems()` in Sources/App/Loader.swift when the list is empty"))
        #expect(!PromptLint.isAlreadyClear(clear.replacingOccurrences(of: "Build must pass.", with: "")))
        #expect(!PromptLint.isAlreadyClear(clear + " Make it better."))
    }

    @Test("conflicts finds a brief clause against a detailed one")
    func conflicts() {
        #expect(PromptLint.conflicts("Keep it short. Explain in great detail.").count == 1)
        #expect(PromptLint.conflicts("Keep it short. Name the file.").isEmpty)
    }

    @Test("already-clear gate: specific drafts with a done-condition pass, vague or unverifiable ones don't")
    func gateSamples() {
        #expect(PromptLint.isAlreadyClear("In `Task.swift`, make `Task` conform to `Equatable` by comparing only `id`; `XCTAssertEqual(task1, task2)` in TaskTests.swift passes when ids match."))
        #expect(PromptLint.isAlreadyClear("Update `Dockerfile` to set `NODE_ENV=production` and replace `npm install` with `npm ci --omit=dev`; `docker build .` completes under 300 MB."))
        #expect(!PromptLint.isAlreadyClear("Refactor the `calculateTotal` function in `BillingService.swift` so it's cleaner."))
        #expect(!PromptLint.isAlreadyClear("Add a new endpoint `GET /v1/users/:id/orders` in `server.ts` that returns orders for that user."))
    }
}
