import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

/// The values below are the real `text_config` of prism-ml/Ternary-Bonsai-2-27B-mlx-2bit
/// (docs/plans/model-facts.md). Each of these was once misread, which made the model emit
/// gibberish while every speed benchmark still passed.
@Suite("Qwen35Config")
struct Qwen35ConfigTests {

    private var bonsai: [String: Any] {
        [
            "hidden_size": 5120, "num_attention_heads": 24, "num_key_value_heads": 4, "head_dim": 256,
            "num_hidden_layers": 64, "intermediate_size": 17408, "vocab_size": 248320,
            "rms_norm_eps": 1e-6, "attn_output_gate": true,
            "rope_theta": NSNull(),                                   // null at the top level
            "partial_rotary_factor": 0.25,
            "rope_parameters": ["rope_theta": 10_000_000, "partial_rotary_factor": 0.25,
                                "mrope_interleaved": true, "mrope_section": [11, 11, 10], "rope_type": "default"],
            "linear_key_head_dim": 128, "linear_value_head_dim": 128,
            "linear_num_key_heads": 16, "linear_num_value_heads": 48,
            "layer_types": (0..<64).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" },
        ]
    }

    @Test("rope theta comes from rope_parameters (1e7), not the null top-level key or a 1e6 default")
    func ropeTheta() {
        #expect(Qwen35Config.from(dict: bonsai).ropeTheta == 10_000_000)
    }

    @Test("only a quarter of each head is rotated: 64 of 256 dims")
    func partialRotary() {
        let c = Qwen35Config.from(dict: bonsai)
        #expect(c.partialRotaryFactor == 0.25)
        #expect(Int(Float(c.headDim) * c.partialRotaryFactor) == 64)
    }

    @Test("model shape fields are read as published")
    func shape() {
        let c = Qwen35Config.from(dict: bonsai)
        #expect(c.hiddenSize == 5120 && c.numAttentionHeads == 24 && c.numKeyValueHeads == 4 && c.headDim == 256)
        #expect(c.numHiddenLayers == 64 && c.vocabSize == 248_320 && c.attnOutputGate)
        #expect(c.linearKeyHeadDim == 128)
        #expect(c.layerTypes.filter { $0 == "full_attention" }.count == 16)
        #expect(c.layerTypes.filter { $0 == "linear_attention" }.count == 48)
        #expect(c.layerTypes[3] == "full_attention" && c.layerTypes[63] == "full_attention")
    }

    @Test("a config without rope_parameters still uses a sane theta and full rotation")
    func fallback() {
        var d = bonsai
        d.removeValue(forKey: "rope_parameters"); d.removeValue(forKey: "rope_theta"); d.removeValue(forKey: "partial_rotary_factor")
        let c = Qwen35Config.from(dict: d)
        #expect(c.ropeTheta == 10_000_000)
        #expect(c.partialRotaryFactor == 1.0)
    }

    @Test("KV bytes per token match the model card arithmetic: 16 full layers × 2 × 4 heads × 256 × 2 B = 64 KiB")
    func kvBytesPerToken() {
        let c = Qwen35Config.from(dict: bonsai)
        let fullLayers = c.layerTypes.filter { $0 == "full_attention" }.count
        #expect(fullLayers * 2 * c.numKeyValueHeads * c.headDim * 2 == 64 * 1024)
    }
}
