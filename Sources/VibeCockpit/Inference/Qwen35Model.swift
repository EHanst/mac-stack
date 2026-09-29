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
    let layerTypes: [String]
    let attnOutputGate: Bool

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
    let attnOutputGate: Bool

    init(weights: [String: MLXArray], prefix: String,
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
        cache: Qwen35LayerCache
    ) -> MLXArray {
        let B = x.shape[0]
        let L = x.shape[1]
        let offset = cache.offset

        // q/k/v read the same activations with the same rotation: rotate once.
        let proj = PrismPackedLinear.project(x, qProj, kProj, vProj)
        let qRaw = proj[0]  // [B, L, nHeads*headDim] or [B, L, 2*nHeads*headDim] if gated
        let qDim = nHeads * headDim
        let gate: MLXArray?
        if attnOutputGate {
            gate = MLXNN.silu(qRaw[0..., 0..., qDim...])
        } else {
            gate = nil
        }
        var q = qRaw[0..., 0..., 0..<qDim].reshaped([B, L, nHeads, headDim]).transposed(0, 2, 1, 3)
        var k = proj[1].reshaped([B, L, nKVHeads, headDim]).transposed(0, 2, 1, 3)
        let v = proj[2].reshaped([B, L, nKVHeads, headDim]).transposed(0, 2, 1, 3)

        if let qn = qNorm { q = qn(q) }
        if let kn = kNorm { k = kn(k) }

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
        if let g = gate { out = out * g }
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
        let gu = PrismPackedLinear.project(x, gateProj, upProj)
        return downProj(MLXNN.silu(gu[0]) * gu[1])
    }
}

// MARK: - Bonsai Linear Attention (Mamba2-style SSM layer)

final class BonsaiLinearAttn: Module, @unchecked Sendable {
    private let inProjQKV: PrismPackedLinear
    private let inProjZ:   PrismPackedLinear
    private let outProj:   PrismPackedLinear
    private let inProjA:   MLXArray   // [nQH, hiddenSize] float dt projection
    private let inProjB:   MLXArray   // [nQH, hiddenSize] float (unused in fwd for now)
    private let aLog:      MLXArray   // [nQH] log state decay
    private let dtBias:    MLXArray   // [nQH] dt bias
    private let conv1dW:   MLXArray   // [dQKV, 4, 1] depthwise conv
    private let headNorm:  Qwen35RMSNorm

    let nQH:    Int   // e.g. 48
    let nKVH:   Int   // e.g. 16
    let headD:  Int   // e.g. 128
    let dInner: Int   // nQH * headD = 6144
    let dQKV:   Int   // nQH*headD + 2*nKVH*headD = 10240

    init(weights: [String: MLXArray], prefix: String,
         config: Qwen35Config, hadamard: HadamardMeta) {
        let aLogW   = weights["\(prefix).A_log"]!
        let zScales = weights["\(prefix).in_proj_z.scales"]!
        let qScales = weights["\(prefix).in_proj_qkv.scales"]!
        let nQH_    = aLogW.shape[0]
        let dZ      = zScales.shape[0]
        let dQ      = qScales.shape[0]
        let hD      = dZ / nQH_
        nQH    = nQH_
        headD  = hD
        dInner = dZ
        dQKV   = dQ
        nKVH   = (dQ - dZ) / (2 * hD)

        func qproj(_ name: String) -> PrismPackedLinear {
            let p = "\(prefix).\(name)"
            let (b, s) = hadamard.rotation(for: p)
            return PrismPackedLinear(
                weight: weights["\(p).weight"]!,
                scales: weights["\(p).scales"]!,
                biases: weights["\(p).biases"]!,
                block: b, signs: s)
        }
        inProjQKV = qproj("in_proj_qkv")
        inProjZ   = qproj("in_proj_z")
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

        // Projections (one shared input rotation for qkv and z)
        let proj = PrismPackedLinear.project(xf, inProjQKV, inProjZ)
        var qkv = proj[0].reshaped([B, L, dQKV])
        let z   = proj[1].reshaped([B, L, dInner])

        // Causal depthwise conv1d over L, continuing from the cached trailing inputs
        qkv = bonsaiCausalConv(qkv, w: conv1dW, cache: cache)
        qkv = MLXNN.silu(qkv)

        // Split Q / K / V
        let kvDim = nKVH * headD
        let Q = qkv[0..., 0..., 0..<dInner].reshaped([B, L, nQH, headD])
        let K = qkv[0..., 0..., dInner..<(dInner + kvDim)].reshaped([B, L, nKVH, headD])
        let V = qkv[0..., 0..., (dInner + kvDim)...].reshaped([B, L, nKVH, headD])

        // GQA: expand K, V from nKVH → nQH heads
        let g  = nQH / nKVH
        let KE = broadcast(K.expandedDimensions(axis: 3),
                           to: [B, L, nKVH, g, headD]).reshaped([B, L, nQH, headD])
        let VE = broadcast(V.expandedDimensions(axis: 3),
                           to: [B, L, nKVH, g, headD]).reshaped([B, L, nQH, headD])

        // Input-dependent timestep
        let dtRaw = MLX.matmul(xf, inProjA.transposed()).reshaped([B, L, nQH])
        let dt    = MLXNN.softplus(dtRaw + dtBias)   // [B, L, nQH]
        let negA  = -MLX.exp(aLog)                   // [nQH]
        let logDecay = dt * negA                     // [B, L, nQH]

        // Recurrence: H_t = exp(logDecay_t)·H_{t-1} + k_t v_tᵀ ;  y_t = q_t·H_t
        let step: (y: MLXArray, h: MLXArray)
        if L == 1 {
            step = bonsaiGenerate(Q: Q, KE: KE, VE: VE, logDecay: logDecay,
                                  hPrev: cache.ssmState, B: B)
        } else {
            step = bonsaiPrefill(Q: Q, KE: KE, VE: VE,
                                 logDecayCum: MLX.cumsum(logDecay, axis: 1),
                                 hPrev: cache.ssmState, B: B, L: L)
        }
        let y = step.y
        cache.ssmState = step.h

        // Per-head norm and gate
        let yNorm = headNorm(y.reshaped([B * L * nQH, headD])).reshaped([B, L, dInner])
        let gate  = MLXNN.silu(z)
        return outProj((yNorm * gate).reshaped([B * L, dInner])).reshaped([B, L, Dm])
    }

    /// Single-token step. Q, KE, VE: [B, 1, nQH, headD], logDecay: [B, 1, nQH],
    /// hPrev: [B, nQH, headD, headD] (nil at the start of a sequence).
    private func bonsaiGenerate(Q: MLXArray, KE: MLXArray, VE: MLXArray,
                                logDecay: MLXArray, hPrev: MLXArray?,
                                B: Int) -> (y: MLXArray, h: MLXArray) {
        let q = Q[0..., 0, 0..., 0...]    // [B, nQH, headD]
        let k = KE[0..., 0, 0..., 0...]   // [B, nQH, headD]
        let v = VE[0..., 0, 0..., 0...]   // [B, nQH, headD]
        let outer = k.expandedDimensions(axis: 3) * v.expandedDimensions(axis: 2)  // [B,nQH,headD,headD]
        let decay1 = MLX.exp(logDecay[0..., 0, 0...]).reshaped([B, nQH, 1, 1])
        let hNew = hPrev.map { decay1 * $0 + outer } ?? outer
        let qm   = q.expandedDimensions(axis: 2)           // [B, nQH, 1, headD]
        let yh   = MLX.matmul(qm, hNew).squeezed(axis: 2)  // [B, nQH, headD]
        return (yh.reshaped([B, 1, nQH * headD]), hNew)
    }

    /// Chunked (parallel) form over L tokens, optionally continuing from `hPrev`.
    ///
    /// With c_t the cumulative log decay within the chunk:
    ///   y_t  = exp(c_t)·(q_t·H₀) + Σ_{s≤t} exp(c_t − c_s)(q_t·k_s) v_s
    ///   H_L  = exp(c_L)·H₀       + Σ_s      exp(c_L − c_s) k_s v_sᵀ
    /// so a long prompt can be prefilled in bounded-size chunks with identical results.
    private func bonsaiPrefill(Q: MLXArray, KE: MLXArray, VE: MLXArray,
                               logDecayCum: MLXArray, hPrev: MLXArray?,
                               B: Int, L: Int) -> (y: MLXArray, h: MLXArray) {
        // All inputs: [B, L, nQH, headD]; logDecayCum: [B, L, nQH]
        let Qh  = Q.transposed(0, 2, 1, 3)                  // [B, nQH, L, headD]
        let Kh  = KE.transposed(0, 2, 1, 3)                 // [B, nQH, L, headD]
        let Vh  = VE.transposed(0, 2, 1, 3)                 // [B, nQH, L, headD]
        let QK  = MLX.matmul(Qh, Kh.transposed(0, 1, 3, 2))  // [B, nQH, L, L]

        // Log decay weight matrix [B, nQH, L_t, L_s], future positions masked to -inf
        let ldc  = logDecayCum.transposed(0, 2, 1)           // [B, nQH, L]
        let logW = MLX.where(
            Self.causalTriangle(L),
            ldc.expandedDimensions(axis: 3) - ldc.expandedDimensions(axis: 2),
            MLXArray(Float(-1e30)))

        var y = MLX.matmul(QK * MLX.exp(logW), Vh)           // [B, nQH, L, headD]

        // State after the chunk
        let lastCum = ldc[0..., 0..., L - 1]                                  // [B, nQH]
        let w   = MLX.exp(lastCum.expandedDimensions(axis: 2) - ldc)          // [B, nQH, L]
        let wKt = (Kh * w.expandedDimensions(axis: 3)).transposed(0, 1, 3, 2) // [B, nQH, headD, L]
        var newH = MLX.matmul(wKt, Vh)                                        // [B, nQH, headD, headD]

        if let h0 = hPrev {
            y = y + MLX.matmul(Qh, h0) * MLX.exp(ldc).expandedDimensions(axis: 3)
            newH = newH + h0 * MLX.exp(lastCum).reshaped([B, nQH, 1, 1])
        }
        return (y.transposed(0, 2, 1, 3).reshaped([B, L, nQH * headD]), newH)
    }

    /// Lower-triangular (including diagonal) boolean mask, built on device.
    private static func causalTriangle(_ L: Int) -> MLXArray {
        let idx = MLXArray(Int32(0) ..< Int32(L))
        return idx[0..., .newAxis] .>= idx[.newAxis]
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

    init(weights: [String: MLXArray], prefix: String,
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

    init(weights: [String: MLXArray], config: Qwen35Config, hadamard: HadamardMeta) {
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
