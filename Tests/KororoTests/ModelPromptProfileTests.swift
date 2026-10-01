import XCTest
@testable import StackCore

final class ModelPromptProfileTests: XCTestCase {
    func testLegacyInitStillCompilesWithDefaults() {
        let p = ModelPromptProfile(family: "t", displayName: "T", structure: .xmlTags,
                                   maxUsefulTokens: 100, guidance: "G")
        XCTAssertEqual(p.reasoningCue, .allow)
        XCTAssertEqual(p.verbosity, .normal)
        XCTAssertEqual(p.rewriterGuidance, "G")
    }

    func testRewriterGuidanceAppendsTypedFields() {
        let p = ModelPromptProfile(family: "r", displayName: "R", structure: .plainNumbered,
                                   maxUsefulTokens: 100, guidance: "G",
                                   reasoningCue: .avoid, outputFormatWording: "End with the format.",
                                   verbosity: .concise)
        XCTAssertTrue(p.rewriterGuidance.contains("Do not ask the model to think step by step."))
        XCTAssertTrue(p.rewriterGuidance.contains("End with the format."))
        XCTAssertTrue(p.rewriterGuidance.contains("Keep the prompt short."))
    }

    func testProviderMapping() {
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "gemini-2.5-pro").family, "gemini")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "o3-mini").family, "reasoning")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "deepseek-r1").family, "deepseek")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:deepseek-r1-distill").family, "local")
    }

    func testReasoningProviderMappings() {
        // O-series reasoning models
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "openai/o1-mini").family, "reasoning")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "openai/o3-pro").family, "reasoning")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "o3-mini").family, "reasoning")
    }

    func testLocalPriorityInMapping() {
        // local: prefix should take priority over other patterns
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:deepseek-r1-distill").family, "local")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:o1-mini").family, "local")
    }

    func testNoFalseO1O3Matching() {
        // Should not match o1/o3 in the middle of words like "bro1ler"
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "bro1ler").family, "generic")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "error3msg").family, "generic")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "model-o1-backup").family, "reasoning")
    }

    func testDeepSeekR1ProfileMapping() {
        // deepseek-r1 should map to deepseekR1 profile, not reasoning
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "deepseek-r1").family, "deepseek")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "deepseek-r1-distill").family, "deepseek")
    }

    func testDeepSeekR1Guidance() {
        // deepseekR1 guidance should NOT contain "think step by step"
        let guidance = ModelPromptProfile.deepseekR1.rewriterGuidance
        XCTAssertFalse(guidance.contains("think step by step"))
        XCTAssertTrue(guidance.contains("DeepSeek-R1"))
        XCTAssertTrue(guidance.contains("plain language"))
    }

    func testDeepSeekR1Properties() {
        let p = ModelPromptProfile.deepseekR1
        XCTAssertEqual(p.family, "deepseek")
        XCTAssertEqual(p.structure, .plainNumbered)
        XCTAssertEqual(p.maxUsefulTokens, 8_000)
        XCTAssertEqual(p.verbosity, .concise)
        XCTAssertEqual(p.reasoningCue, .allow)
    }

    func testTargetProfileFamilySupportsDeepSeek() {
        let t = TargetProfile.make(modelFamily: "deepseek", surface: .other)
        XCTAssertEqual(t.model.family, "deepseek")
        XCTAssertEqual(t.model, .deepseekR1)
    }

    func testClaudeCodeGuidance() {
        let p = ModelPromptProfile.claudeCode
        XCTAssertFalse(p.guidance.contains("Reference files by path"))
        XCTAssertTrue(p.guidance.contains("State the goal"))
        XCTAssertTrue(p.guidance.contains("name the files and symbols"))
        XCTAssertTrue(p.guidance.contains("what done looks like"))
    }

    func testOpenrouterQwenIsGeneric() {
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "openrouter/qwen3-coder").family, "generic")
    }

    func testLocalModelStillMapsBonsai() {
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "bonsai-27b").family, "local")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:bonsai-27b").family, "local")
    }

    func testQuickLocalQwenAndMlx() {
        // With local: prefix, these should be local
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:qwen35").family, "local")
        XCTAssertEqual(ModelPromptProfile.profile(forProviderID: "local:mlx-something").family, "local")
    }
}
