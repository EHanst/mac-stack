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
    /// Fraction of each head's dims that get rotary embeddings (0.25 ⇒ 64 of 256).
    let partialRotaryFactor: Float
    let linearKeyHeadDim: Int?
    let headDim: Int
    let layerTypes: [String]
    let attnOutputGate: Bool

    var kvHeads: Int { numKeyValueHeads }
    var groups: Int { numAttentionHeads / numKeyValueHeads }

    static func from(dict: [String: Any]) -> Qwen35Config {
        let hiddenSize  = dict["hidden_size"]         as? Int ?? 5120
        let nHeads      = dict["num_attention_heads"] as? Int ?? 40
        let headDim     = (dict["head_dim"]           as? Int) ?? (hiddenSize / nHeads)
        let ropeParams  = dict["rope_parameters"]     as? [String: Any]
        return Qwen35Config(
            vocabSize:         dict["vocab_size"]             as? Int    ?? 248320,
            hiddenSize:        hiddenSize,
            numHiddenLayers:   dict["num_hidden_layers"]       as? Int    ?? 64,
            numAttentionHeads: nHeads,
            numKeyValueHeads:  dict["num_key_value_heads"]     as? Int    ?? 8,
            intermediateSize:  dict["intermediate_size"]       as? Int    ?? 25600,
            rmsNormEps:        Float(dict["rms_norm_eps"]      as? Double ?? 1e-6),
            // Qwen3.5 keeps rope settings in `rope_parameters`; a top-level `rope_theta` is null.
            ropeTheta:         Float(ropeParams?["rope_theta"] as? Double ?? dict["rope_theta"] as? Double ?? 10_000_000.0),
            partialRotaryFactor: Float(ropeParams?["partial_rotary_factor"] as? Double
                                       ?? dict["partial_rotary_factor"] as? Double ?? 1.0),
            linearKeyHeadDim:  dict["linear_key_head_dim"]     as? Int,
            headDim:           headDim,
            layerTypes:        dict["layer_types"]             as? [String] ?? [],
            attnOutputGate:    dict["attn_output_gate"]        as? Bool    ?? false
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
    private let qkvProj: PrismFusedLinear
    private let oProj: PrismPackedLinear
    private let qNorm: Qwen35RMSNorm?
    private let kNorm: Qwen35RMSNorm?
    private let rope: RoPE
    let nHeads: Int
    let nKVHeads: Int
    let headDim: Int
    let attnOutputGate: Bool

    init(weights: WeightStore, prefix: String,
         config: Qwen35Config, hadamard: HadamardMeta) {
        attnOutputGate = config.attnOutputGate
        // With attn_output_gate, q_proj outputs 2×(nHeads×headDim); use config values for heads
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

        qkvProj = PrismFusedLinear(
            store: weights,
            prefixes: ["q_proj", "k_proj", "v_proj"].map { "\(prefix).\($0)" },
            hadamard: hadamard)
        oProj = proj("o_proj")
        qNorm = rmsNorm("q_norm")
        kNorm = rmsNorm("k_norm")
        // Partial rotary: only the first `partialRotaryFactor × headDim` dims are rotated.
        let ropeDims = max(1, Int(Float(config.headDim) * config.partialRotaryFactor))
        rope  = RoPE(dimensions: ropeDims, traditional: false, base: config.ropeTheta)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: Qwen35LayerCache
    ) -> MLXArray {
        let B = x.shape[0]
        let L = x.shape[1]
        let offset = cache.offset

        let proj = qkvProj(x)  // one fused matmul → [q, k, v]
        let qDim = nHeads * headDim
        // With the output gate, q_proj emits per head [query_h | gate_h] (width 2·headDim each).
        let qHeads = proj[0].reshaped([B, L, nHeads, -1])
        var q: MLXArray
        let gate: MLXArray?
        if attnOutputGate {
            let parts = qHeads.split(parts: 2, axis: -1)
            q = parts[0]
            gate = parts[1].reshaped([B, L, qDim])
        } else {
            q = qHeads
            gate = nil
        }
        var k = proj[1].reshaped([B, L, nKVHeads, headDim])
        let v = proj[2].reshaped([B, L, nKVHeads, headDim]).transposed(0, 2, 1, 3)

        if let qn = qNorm { q = qn(q) }
        if let kn = kNorm { k = kn(k) }
        q = q.transposed(0, 2, 1, 3)
        k = k.transposed(0, 2, 1, 3)

        q = rope(q, offset: offset)
        k = rope(k, offset: offset)

        let (kAll, vAll) = cache.updateKV(keys: k, values: v)

        // The fused SDPA kernel handles grouped-query attention natively; keys/values must
        // NOT be tiled up to nHeads (that materialised a copy of the whole KV history per
        // layer per token).
        let scale = 1.0 / Float(headDim).squareRoot()
        let attn = MLXFast.scaledDotProductAttention(
            queries: q, keys: kAll, values: vAll, scale: scale, mask: mask)
        var out = attn.transposed(0, 2, 1, 3).reshaped([B, L, qDim])
        if let g = gate { out = out * MLXNN.sigmoid(g) }   // Qwen3.5 reference: sigmoid gate
        return oProj(out)
    }
}

// MARK: - MLP

final class Qwen35MLP: Module, @unchecked Sendable {
    private let gateUpProj: PrismFusedLinear
    private let downProj:   PrismPackedLinear

    init(weights: WeightStore, prefix: String, hadamard: HadamardMeta) {
        func proj(_ name: String) -> PrismPackedLinear {
            let p = "\(prefix).\(name)"
            let (b, s) = hadamard.rotation(for: p)
            return PrismPackedLinear(
                weight: weights["\(p).weight"]!,
                scales: weights["\(p).scales"]!,
                biases: weights["\(p).biases"]!,
                block: b, signs: s)
        }
        gateUpProj = PrismFusedLinear(
            store: weights,
            prefixes: ["gate_proj", "up_proj"].map { "\(prefix).\($0)" },
            hadamard: hadamard)
        downProj = proj("down_proj")
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let gu = gateUpProj(x)
        return downProj(MLXNN.silu(gu[0]) * gu[1])
    }
}

// MARK: - Gated DeltaNet (Qwen3.5 linear attention)

/// Qwen3.5's linear-attention layer: causal conv → q/k/v split → q/k normalisation → gated
/// delta-rule recurrence (`GatedDelta`) → per-head RMSNorm gated by `silu(z)` → output projection.
/// Written against mlx-swift-lm's `Qwen35GatedDeltaNet`, with the Prism-packed linears.
final class BonsaiLinearAttn: Module, @unchecked Sendable {
    private let inProjQKVZ: PrismFusedLinear
    private let outProj:   PrismPackedLinear
    private let inProjA:   MLXArray   // [nV, hidden] float — timestep input
    private let inProjB:   MLXArray   // [nV, hidden] float — write-strength (β) input
    private let aLog:      MLXArray   // [nV]
    private let dtBias:    MLXArray   // [nV]
    private let conv1dW:   MLXArray   // [convDim, K, 1] depthwise
    private let headNorm:  Qwen35RMSNorm

    let nV:      Int   // value heads (48)
    let nK:      Int   // key heads (16)
    let headK:   Int   // 128
    let headV:   Int   // 128
    let keyDim:  Int   // nK · headK
    let valueDim: Int  // nV · headV
    let convDim: Int   // 2·keyDim + valueDim

    /// The recurrent state is kept in float32 (`mamba_ssm_dtype` in the model config).
    private static let stateDType: DType = .float32

    init(weights: WeightStore, prefix: String,
         config: Qwen35Config, hadamard: HadamardMeta) {
        let aLogW   = weights["\(prefix).A_log"]!
        let zScales = weights["\(prefix).in_proj_z.scales"]!
        let qScales = weights["\(prefix).in_proj_qkv.scales"]!
        nV        = aLogW.shape[0]
        valueDim  = zScales.shape[0]
        convDim   = qScales.shape[0]
        headV     = valueDim / nV
        headK     = config.linearKeyHeadDim ?? headV
        keyDim    = (convDim - valueDim) / 2
        nK        = keyDim / headK
        precondition(2 * keyDim + valueDim == convDim && nV % nK == 0 && headK % 32 == 0,
                     "unexpected Gated DeltaNet shapes in \(prefix)")

        func qproj(_ name: String) -> PrismPackedLinear {
            let p = "\(prefix).\(name)"
            let (b, s) = hadamard.rotation(for: p)
            return PrismPackedLinear(
                weight: weights["\(p).weight"]!,
                scales: weights["\(p).scales"]!,
                biases: weights["\(p).biases"]!,
                block: b, signs: s)
        }
        inProjQKVZ = PrismFusedLinear(
            store: weights,
            prefixes: ["in_proj_qkv", "in_proj_z"].map { "\(prefix).\($0)" },
            hadamard: hadamard)
        outProj   = qproj("out_proj")
        inProjA   = weights["\(prefix).in_proj_a.weight"]!
        inProjB   = weights["\(prefix).in_proj_b.weight"]!
        aLog      = aLogW
        dtBias    = weights["\(prefix).dt_bias"]!
        conv1dW   = weights["\(prefix).conv1d.weight"]!
        headNorm  = Qwen35RMSNorm(weight: weights["\(prefix).norm.weight"]!,
                                  eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: Qwen35LayerCache) -> MLXArray {
        let B  = x.shape[0]
        let L  = x.shape[1]
        let Dm = x.shape[2]
        let xf = x.reshaped([B * L, Dm])

        let proj = inProjQKVZ(xf)                                   // one fused matmul: qkv, z
        var qkv = proj[0].reshaped([B, L, convDim])
        let z   = proj[1].reshaped([B, L, nV, headV])
        let b   = MLX.matmul(xf, inProjB.transposed()).reshaped([B, L, nV])
        let a   = MLX.matmul(xf, inProjA.transposed()).reshaped([B, L, nV])

        qkv = MLXNN.silu(bonsaiCausalConv(qkv, w: conv1dW, cache: cache))

        // Layout is [q (keyDim) | k (keyDim) | v (valueDim)].
        let q = qkv[0..., 0..., 0..<keyDim].reshaped([B, L, nK, headK])
        let k = qkv[0..., 0..., keyDim..<(2 * keyDim)].reshaped([B, L, nK, headK])
        let v = qkv[0..., 0..., (2 * keyDim)...].reshaped([B, L, nV, headV])

        // q, k are RMS-normalised (no weight) and scaled: q by 1/Dk, k by 1/√Dk.
        let invScale = 1.0 / Float(headK).squareRoot()
        let qN = MLXArray(invScale * invScale).asType(q.dtype) * MLXFast.rmsNorm(q, weight: MLXArray.mlxNone, eps: 1e-6)
        let kN = MLXArray(invScale).asType(k.dtype) * MLXFast.rmsNorm(k, weight: MLXArray.mlxNone, eps: 1e-6)

        let g    = GatedDelta.decay(aLog: aLog, a: a, dtBias: dtBias)      // [B, L, nV] float32
        let beta = MLXNN.sigmoid(b.asType(.float32))
        let state = cache.ssmState
            ?? MLXArray.zeros([B, nV, headV, headK], dtype: Self.stateDType)
        let (y, newState) = GatedDelta.update(q: qN, k: kN, v: v, g: g, beta: beta, state: state)
        cache.ssmState = newState

        let gated = headNorm(y) * MLXNN.silu(z)                     // per-head RMSNorm, gated by silu(z)
        return outProj(gated.reshaped([B * L, valueDim])).reshaped([B, L, Dm])
    }

    /// Depthwise causal conv (kernel K) that continues from the K-1 inputs cached from the
    /// previous chunk / decode step instead of restarting from zero padding every call.
    private func bonsaiCausalConv(_ x: MLXArray, w: MLXArray, cache: Qwen35LayerCache) -> MLXArray {
        // x: [B, L, C]; w: [C, K, 1]
        let B = x.shape[0], L = x.shape[1], C = x.shape[2]
        let K = w.shape[1]
        let wk = w.reshaped([C, K])  // [C, K]
        let history = cache.convState ?? MLXArray.zeros([B, K - 1, C], dtype: x.dtype)
        let padded = concatenated([history, x], axis: 1)  // [B, L+K-1, C]
        // Last K-1 rows; contiguous() so the state doesn't pin the whole padded chunk.
        cache.convState = contiguous(padded[0..., L..., 0...])
        var out = padded[0..., 0..<L, 0...] * wk[0..., 0]
        for i in 1..<K {
            out = out + padded[0..., i..<(i + L), 0...] * wk[0..., i]
        }
        return out
    }
}

// MARK: - Decoder layer

final class Qwen35DecoderLayer: Module, @unchecked Sendable {
    private let selfAttn:          Qwen35Attention?
    private let linearAttn:        BonsaiLinearAttn?
    private let mlp:               Qwen35MLP
    private let inputLayerNorm:    Qwen35RMSNorm
    private let postAttnLayerNorm: Qwen35RMSNorm

    init(weights: WeightStore, prefix: String,
         config: Qwen35Config, hadamard: HadamardMeta,
         layerType: String = "full_attention") {
        if layerType == "linear_attention" {
            selfAttn   = nil
            linearAttn = BonsaiLinearAttn(
                weights: weights, prefix: "\(prefix).linear_attn",
                config: config, hadamard: hadamard)
        } else {
            selfAttn   = Qwen35Attention(
                weights: weights, prefix: "\(prefix).self_attn",
                config: config, hadamard: hadamard)
            linearAttn = nil
        }
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
        cache: Qwen35LayerCache
    ) -> MLXArray {
        let normed = inputLayerNorm(x)
        let attnOut: MLXArray
        if let attn = selfAttn {
            attnOut = attn(normed, mask: mask, cache: cache)
        } else if let attn = linearAttn {
            attnOut = attn(normed, cache: cache)
        } else {
            attnOut = MLXArray.zeros(x.shape).asType(x.dtype)
        }
        var h = x + attnOut
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

    init(weights: WeightStore, config: Qwen35Config, hadamard: HadamardMeta) {
        self.config = config
        let (eb, es) = hadamard.rotation(for: "model.embed_tokens")
        embedTokens = PrismPackedEmbedding(
            weight: weights["model.embed_tokens.weight"]!,
            scales: weights["model.embed_tokens.scales"]!,
            biases: weights["model.embed_tokens.biases"]!,
            block: eb, signs: es)

        layers = (0..<config.numHiddenLayers).map { i in
            let lt = config.layerTypes.count > i ? config.layerTypes[i] : "full_attention"
            return Qwen35DecoderLayer(
                weights: weights, prefix: "model.layers.\(i)",
                config: config, hadamard: hadamard, layerType: lt)
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

    func makeCache() -> Qwen35Cache { Qwen35Cache(layerCount: config.numHiddenLayers) }

    /// Attention mask for `length` new tokens appended after `offset` cached ones.
    static func attentionMask(length L: Int, offset: Int) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if L == 1 { return .none }
        if offset == 0 { return .causal }
        // Chunked prefill: new queries also attend to every cached key.
        let total = offset + L
        let rinds = MLXArray(Int32(0) ..< Int32(total))
        let linds = MLXArray(Int32(offset) ..< Int32(total))
        return .array(linds[0..., .newAxis] .>= rinds[.newAxis])
    }

    /// Run all decoder layers, updating `cache`. Returns hidden states `[B, L, hidden]`.
    private func hidden(_ tokens: MLXArray, cache: Qwen35Cache) -> MLXArray {
        let L = tokens.shape[1]
        var h = embedTokens(tokens)
        let mask = Self.attentionMask(length: L, offset: cache.tokenCount)
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache.layers[i])
        }
        cache.advance(by: L)
        return h
    }

    /// Feed tokens through the model only to populate `cache` (no final norm / LM head).
    /// The caller evaluates `cache.stateArrays`; the last layer's MLP output is never needed
    /// and is therefore never computed.
    func prefill(_ tokens: MLXArray, cache: Qwen35Cache) {
        _ = hidden(tokens, cache: cache)
    }

    /// Logits `[1, vocab]` for the last position of `tokens` (`[1, L]`).
    func callAsFunction(_ tokens: MLXArray, cache: Qwen35Cache) -> MLXArray {
        let h = norm(hidden(tokens, cache: cache))
        // Extract last-token hidden state: [1, hiddenSize]
        let lastH = h[0, h.shape[1] - 1].expandedDimensions(axis: 0)
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
                case let arr as MLXArray:
                    arrays.append(arr)
                case let mod as Module:
                    collect(mod)
                case let mods as [Module]:
                    mods.forEach { collect($0) }
                default:
                    // Unwrap Optional<Module> via reflection
                    let cm = Mirror(reflecting: child.value)
                    if cm.displayStyle == .optional,
                       let wrapped = cm.children.first?.value as? Module {
                        collect(wrapped)
                    }
                }
            }
        }
        collect(self)
        return arrays
    }
}
