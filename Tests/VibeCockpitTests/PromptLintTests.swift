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
}
