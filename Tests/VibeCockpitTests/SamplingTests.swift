import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("Sampling parameters")
struct SamplingTests {

    @Test("presets match the Ternary-Bonsai model card exactly")
    func presets() {
        // Card: instruct/non-thinking T=0.7 top_p=0.80 top_k=20 presence=1.5; thinking T=1.0 top_p=0.95 top_k=20 presence=0.
        #expect(SamplingParameters.bonsaiInstruct == SamplingParameters(temperature: 0.7, topK: 20, topP: 0.8, presencePenalty: 1.5))
        #expect(SamplingParameters.bonsaiThinking == SamplingParameters(temperature: 1.0, topK: 20, topP: 0.95, presencePenalty: 0))
    }

    @Test("greedy is only temperature 0")
    func greedy() {
        #expect(SamplingParameters.greedy.isGreedy)
        #expect(!SamplingParameters.bonsaiInstruct.isGreedy)
        #expect(SamplingParameters(temperature: 0, topK: 5, presencePenalty: 1).isGreedy)   // penalty still applies, then argmax
    }

    @Test("generation defaults: a chat reply is bounded (8192 new tokens), local sampling defers to the provider")
    func optionDefaults() {
        let o = GenerationOptions()
        #expect(o.maxTokens == 8192)
        #expect(o.sampling == nil)
        #expect(o.maxTokens <= 16_384)          // fits gpt-4o's maximum output
        #expect(GenerationOptions(sampling: .greedy).sampling == .greedy)
    }
}
