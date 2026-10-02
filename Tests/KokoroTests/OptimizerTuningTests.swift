import Testing
import Foundation
@testable import StackCore

@Suite("OptimizerTuning")
struct OptimizerTuningTests {

    @Test("each local model is recognised by its folder name; everything else keeps the baseline")
    func selection() {
        #expect(OptimizerTuning.forModel("local:Qwen3.5-9B-OptiQ-4bit") == .qwen35_9b)
        #expect(OptimizerTuning.forModel("local:Qwen3.5-4B-OptiQ-4bit") == .standard)
        #expect(OptimizerTuning.forModel("local:Bonsai-27B") == .standard)
        #expect(OptimizerTuning.forModel("anthropic:claude") == .standard)
        #expect(OptimizerTuning.forModel(nil) == .standard)
    }

    @Test("the baseline adds nothing to the request, so a model without an entry sends exactly what it always did")
    func baselineRequestUnchanged() {
        let plain = OptimizeContext(profile: .localSmall)
        let tuned = OptimizeContext(profile: .localSmall, tuning: .standard)
        for mode in [OptimizeMode.improve, .expand, .adapt] {
            func text(_ c: OptimizeContext) -> [String] {
                PromptOptimizer.requestMessages(draft: "make it faster", context: c, mode: mode, useSharedPrefix: false).map(\.content)
            }
            #expect(text(plain) == text(tuned))
        }
        #expect(OptimizerTuning.standard.sampling == .rewrite && OptimizerTuning.standard.extraRules.isEmpty)
    }

    @Test("a model's extra rule reaches only its own request, and never an adapt")
    func extraRuleScoped() {
        let tuning = OptimizerTuning(extraRules: [.improve: "Keep it short."])
        let with = OptimizeContext(profile: .localSmall, tuning: tuning)
        let without = OptimizeContext(profile: .localSmall, tuning: .standard)
        func text(_ c: OptimizeContext, _ m: OptimizeMode) -> String {
            PromptOptimizer.requestMessages(draft: "make it faster", context: c, mode: m, useSharedPrefix: false)
                .map(\.content).joined()
        }
        #expect(text(with, .improve).contains("8. Keep it short."))
        #expect(!text(without, .improve).contains("Keep it short."))
        #expect(!text(with, .adapt).contains("Keep it short."))   // no rule set for adapt
        #expect(!text(with, .expand).contains("Keep it short."))
    }
}
