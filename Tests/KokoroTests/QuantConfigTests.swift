import Testing
import Foundation
@testable import StackCore

@Suite struct QuantConfigTests {
    @Test func missingBlockDefaultsToBonsai() {
        let q = QuantConfig(configDict: ["model_type": "qwen3_5"])
        #expect(q.spec(for: "model.layers.0.mlp.up_proj") == .bonsai)
    }

    @Test func mixedPrecisionOverridesStripLanguageModelPrefix() {
        let q = QuantConfig(configDict: ["quantization": [
            "group_size": 64, "bits": 4, "mode": "affine",
            "language_model.model.embed_tokens": ["bits": 8, "group_size": 64],
            "language_model.model.layers.0.linear_attn.out_proj": ["bits": 8, "group_size": 64],
        ] as [String: Any]])
        #expect(q.spec(for: "model.embed_tokens") == QuantSpec(bits: 8, groupSize: 64))
        #expect(q.spec(for: "model.layers.0.linear_attn.out_proj").bits == 8)
        // Not overridden: falls back to the block default.
        #expect(q.spec(for: "model.layers.0.mlp.up_proj") == QuantSpec(bits: 4, groupSize: 64))
    }

    @Test func nonModuleEntriesAreIgnored() {
        // "mode" is a string, not a per-module dict.
        let q = QuantConfig(configDict: ["quantization": ["bits": 4, "group_size": 64, "mode": "affine"] as [String: Any]])
        #expect(q.overrides.isEmpty)
    }
}
