import MLX
import MLXNN
import MLXRandom

// MARK: - Config

struct Qwen35Config {
    let vocabSize: Int
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let intermediateSize: Int
    let rmsNormEps: Float
    let ropeTheta: Float
    let headDim: Int

    var kvHeads: Int { numKeyValueHeads }
    var groups: Int { numAttentionHeads / numKeyValueHeads }

    static func from(dict: [String: Any]) -> Qwen35Config {
        let hiddenSize  = dict["hidden_size"]         as? Int ?? 5120
        let nHeads      = dict["num_attention_heads"] as? Int ?? 40
        let headDim     = (dict["head_dim"]           as? Int) ?? (hiddenSize / nHeads)
        return Qwen35Config(
            vocabSize:         dict["vocab_size"]             as? Int    ?? 151936,
            hiddenSize:        hiddenSize,
            numHiddenLayers:   dict["num_hidden_layers"]       as? Int    ?? 64,
            numAttentionHeads: nHeads,
            numKeyValueHeads:  dict["num_key_value_heads"]     as? Int    ?? 8,
            intermediateSize:  dict["intermediate_size"]       as? Int    ?? 25600,
            rmsNormEps:        Float(dict["rms_norm_eps"]      as? Double ?? 1e-6),
            ropeTheta:         Float(dict["rope_theta"]        as? Double ?? 1_000_000.0),
            headDim:           headDim
        )
    }
}

// MARK: - Hadamard metadata

struct HadamardMeta: @unchecked Sendable {
    let block: Int
    /// Weight key prefix → signs MLXArray (nil if no rotation for that key)
    let rotations: [String: MLXArray?]
    let embeddingKeys: Set<String>

    static let none = HadamardMeta(block: 0, rotations: [:], embeddingKeys: [])

    func rotation(for prefix: String) -> (block: Int, signs: MLXArray?) {
        guard block > 0, rotations[prefix] != nil else { return (0, nil) }
        return (block, rotations[prefix]!)
    }

    func isEmbedding(_ prefix: String) -> Bool {
        embeddingKeys.contains { prefix.hasPrefix($0) || prefix == $0 }
    }
}

// MARK: - Layer helpers

private final class Qwen35RMSNorm: Module, UnaryLayer, @unchecked Sendable {
    let weight: MLXArray
    let eps: Float
    init(weight: MLXArray, eps: Float) { self.weight = weight; self.eps = eps; super.init() }
    func callAsFunction(_ x: MLXArray) -> MLXArray { MLXFast.rmsNorm(x, weight: weight, eps: eps) }
}

// MARK: - Attention

final class Qwen35Attention: Module, @unchecked Sendable {
    private let qProj: PrismPackedLinear
    private let kProj: PrismPackedLinear
    private let vProj: PrismPackedLinear
    private let oProj: PrismPackedLinear
    private let qNorm: Qwen35RMSNorm?
    private let kNorm: Qwen35RMSNorm?
    private let rope: RoPE
    let nHeads: Int
    let nKVHeads: Int
    let headDim: Int

    init(weights: [String: MLXArray], prefix: String,
         config: Qwen35Config, hadamard: HadamardMeta) {
        nHeads   = config.numAttentionHeads
        nKVHeads = config.numKeyValueHeads
        headDim  = config.headDim

        func proj(_ name: String) -> PrismPackedLinear {
            let p = "\(prefix).\(name)"
            let (b, s) = hadamard.rotation(for: p)
            return PrismPackedLinear(
                weight: weights["\(p).weight"]!,
                scales: weights["\(p).scales"]!,
                biases: weights["\(p).biases"]!,
                block: b, signs: s)
        }
        func rmsNorm(_ name: String) -> Qwen35RMSNorm? {
            guard let w = weights["\(prefix).\(name).weight"] else { return nil }
            return Qwen35RMSNorm(weight: w, eps: config.rmsNormEps)
        }

        qProj = proj("q_proj")
        kProj = proj("k_proj")
        vProj = proj("v_proj")
        oProj = proj("o_proj")
        qNorm = rmsNorm("q_norm")
        kNorm = rmsNorm("k_norm")
        rope  = RoPE(dimensions: headDim, traditional: false, base: config.ropeTheta)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: inout (key: MLXArray, value: MLXArray)?
    ) -> MLXArray {
        let B = x.shape[0]
        let L = x.shape[1]
        let offset = cache?.key.shape[2] ?? 0

        var q = qProj(x).reshaped([B, L, nHeads,   headDim]).transposed(0, 2, 1, 3)
        var k = kProj(x).reshaped([B, L, nKVHeads, headDim]).transposed(0, 2, 1, 3)
        var v = vProj(x).reshaped([B, L, nKVHeads, headDim]).transposed(0, 2, 1, 3)

        if let qn = qNorm { q = qn(q) }
        if let kn = kNorm { k = kn(k) }

        q = rope(q, offset: offset)
        k = rope(k, offset: offset)

        if let c = cache {
            k = concatenated([c.key,   k], axis: 2)
            v = concatenated([c.value, v], axis: 2)
        }
        cache = (key: k, value: v)

        let S = k.shape[2]
        let kFull: MLXArray
        let vFull: MLXArray
        if nHeads != nKVHeads {
            let g = nHeads / nKVHeads
            kFull = broadcast(k.expandedDimensions(axis: 2),
                              to: [B, nKVHeads, g, S, headDim])
                .reshaped([B, nHeads, S, headDim])
            vFull = broadcast(v.expandedDimensions(axis: 2),
                              to: [B, nKVHeads, g, S, headDim])
                .reshaped([B, nHeads, S, headDim])
        } else {
            kFull = k
            vFull = v
        }

        let scale = 1.0 / Float(headDim).squareRoot()
        let attn = MLXFast.scaledDotProductAttention(
            queries: q, keys: kFull, values: vFull, scale: scale, mask: mask)
        let out = attn.transposed(0, 2, 1, 3).reshaped([B, L, nHeads * headDim])
        return oProj(out)
    }
}

// MARK: - MLP

final class Qwen35MLP: Module, @unchecked Sendable {
    private let gateProj: PrismPackedLinear
    private let upProj:   PrismPackedLinear
    private let downProj: PrismPackedLinear

    init(weights: [String: MLXArray], prefix: String, hadamard: HadamardMeta) {
        func proj(_ name: String) -> PrismPackedLinear {
            let p = "\(prefix).\(name)"
            let (b, s) = hadamard.rotation(for: p)
            return PrismPackedLinear(
                weight: weights["\(p).weight"]!,
                scales: weights["\(p).scales"]!,
                biases: weights["\(p).biases"]!,
                block: b, signs: s)
        }
        gateProj = proj("gate_proj")
        upProj   = proj("up_proj")
        downProj = proj("down_proj")
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(MLXNN.silu(gateProj(x)) * upProj(x))
    }
}

// MARK: - Decoder layer

final class Qwen35DecoderLayer: Module, @unchecked Sendable {
    private let selfAttn:          Qwen35Attention
    private let mlp:               Qwen35MLP
    private let inputLayerNorm:    Qwen35RMSNorm
    private let postAttnLayerNorm: Qwen35RMSNorm

    init(weights: [String: MLXArray], prefix: String,
         config: Qwen35Config, hadamard: HadamardMeta) {
        selfAttn = Qwen35Attention(
            weights: weights, prefix: "\(prefix).self_attn", config: config, hadamard: hadamard)
        mlp = Qwen35MLP(
            weights: weights, prefix: "\(prefix).mlp", hadamard: hadamard)
        inputLayerNorm = Qwen35RMSNorm(
            weight: weights["\(prefix).input_layernorm.weight"]!,
            eps: config.rmsNormEps)
        postAttnLayerNorm = Qwen35RMSNorm(
            weight: weights["\(prefix).post_attention_layernorm.weight"]!,
            eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: inout (key: MLXArray, value: MLXArray)?
    ) -> MLXArray {
        var h = x + selfAttn(inputLayerNorm(x), mask: mask, cache: &cache)
        h = h + mlp(postAttnLayerNorm(h))
        return h
    }
}

// MARK: - Full model

final class Qwen35ForCausalLM: Module, @unchecked Sendable {
    private let embedTokens: PrismPackedEmbedding
    private let layers:      [Qwen35DecoderLayer]
    private let norm:        Qwen35RMSNorm
    private let lmHead:      PrismPackedLinear?
    private let lmHeadEmbed: PrismPackedEmbedding?
    let config: Qwen35Config

    init(weights: [String: MLXArray], config: Qwen35Config, hadamard: HadamardMeta) {
        self.config = config
        let (eb, es) = hadamard.rotation(for: "model.embed_tokens")
        embedTokens = PrismPackedEmbedding(
            weight: weights["model.embed_tokens.weight"]!,
            scales: weights["model.embed_tokens.scales"]!,
            biases: weights["model.embed_tokens.biases"]!,
            block: eb, signs: es)

        layers = (0..<config.numHiddenLayers).map { i in
            Qwen35DecoderLayer(
                weights: weights, prefix: "model.layers.\(i)",
                config: config, hadamard: hadamard)
        }

        norm = Qwen35RMSNorm(
            weight: weights["model.norm.weight"]!,
            eps: config.rmsNormEps)

        if let hw = weights["lm_head.weight"], let hs = weights["lm_head.scales"],
           let hb = weights["lm_head.biases"] {
            let (hblock, hsigns) = hadamard.rotation(for: "lm_head")
            lmHead      = PrismPackedLinear(weight: hw, scales: hs, biases: hb, block: hblock, signs: hsigns)
            lmHeadEmbed = nil
        } else {
            lmHead      = nil
            lmHeadEmbed = embedTokens
        }
        super.init()
    }

    func callAsFunction(
        _ tokens: MLXArray,
        cache: inout [(key: MLXArray, value: MLXArray)?]
    ) -> MLXArray {
        let L = tokens.shape[1]
        let offset = cache[0]?.key.shape[2] ?? 0

        var h = embedTokens(tokens)

        let mask: MLXFast.ScaledDotProductAttentionMaskMode
        if L > 1 {
            mask = .causal
        } else {
            mask = .none
        }

        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: &cache[i])
        }

        h = norm(h)
        // Extract last-token hidden state: [B, hiddenSize]
        let lastH = h[0, h.shape[1] - 1].expandedDimensions(axis: 0)  // [1, hiddenSize]
        if let head = lmHead {
            return head(lastH)
        } else {
            return lmHeadEmbed!.asLMHead(lastH)
        }
    }

    func allArrays() -> [MLXArray] {
        var arrays: [MLXArray] = []
        func collect(_ m: Module) {
            let mirror = Mirror(reflecting: m)
            for child in mirror.children {
                switch child.value {
                case let arr as MLXArray: arrays.append(arr)
                case let mod as Module:   collect(mod)
                case let mods as [Module]: mods.forEach { collect($0) }
                default: break
                }
            }
        }
        collect(self)
        return arrays
    }
}
