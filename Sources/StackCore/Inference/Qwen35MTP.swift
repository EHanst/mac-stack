import Foundation
import MLX
import MLXNN

/// Qwen3.5's multi-token-prediction head: one extra full-attention decoder layer that, given the
/// main model's hidden state at position t and the embedding of the token sampled from it, predicts the
/// token after that. Its weights ship beside the model (`optiq/mtp.safetensors`).
///
///     x = fc([norm_e(embed(token_{t+1})), norm_h(hidden_t)])
///     out = norm(layer(x))        logits = lm_head(out)        // predicts token_{t+2}
final class Qwen35MTP: Module, @unchecked Sendable {
    private let fc: MLXArray                 // [hidden, 2·hidden], dense
    private let preEmbedNorm: Qwen35RMSNorm
    private let preHiddenNorm: Qwen35RMSNorm
    private let layer: Qwen35DecoderLayer
    private let norm: Qwen35RMSNorm

    /// The head's RMSNorm weights ship as in the original Qwen checkpoint, where the norm computes
    /// `x̂ · (1 + w)`; our norm is plain `x̂ · w` (the main model's norms in this pack were shifted by 1).
    /// The pack doesn't say which of the head's norms are still unshifted, so follow OptiQ's rule for
    /// this file: a norm whose mean is below 0.5 is unshifted. (Shifting them all, including the final
    /// norm and q_norm, whose means are above that, cut acceptance to chance.)
    static func loadTensors(from url: URL) throws -> [String: MLXArray] {
        var tensors = try MLX.loadArrays(url: url)
        let normSuffixes = ["input_layernorm.weight", "post_attention_layernorm.weight", "q_norm.weight",
                            "k_norm.weight", "pre_fc_norm_hidden.weight", "pre_fc_norm_embedding.weight", "norm.weight"]
        for (key, value) in tensors where normSuffixes.contains(where: { key.hasSuffix($0) }) {
            if value.asType(.float32).mean().item(Float.self) < 0.5 {
                tensors[key] = value + MLXArray(1, dtype: value.dtype)
            }
        }
        return tensors
    }

    init(weights: WeightStore, config: Qwen35Config) {
        fc = weights["mtp.fc.weight"]!
        preEmbedNorm = Qwen35RMSNorm(weight: weights["mtp.pre_fc_norm_embedding.weight"]!, eps: config.rmsNormEps)
        preHiddenNorm = Qwen35RMSNorm(weight: weights["mtp.pre_fc_norm_hidden.weight"]!, eps: config.rmsNormEps)
        layer = Qwen35DecoderLayer(weights: weights, prefix: "mtp.layers.0", config: config,
                                   hadamard: .none, layerType: "full_attention")
        norm = Qwen35RMSNorm(weight: weights["mtp.norm.weight"]!, eps: config.rmsNormEps)
        super.init()
    }

    /// Final-normed output `[B, L, hidden]` for `L` positions at once (causal within the call).
    func callAsFunction(embeds: MLXArray, hidden: MLXArray, embeddingFirst: Bool,
                        cache: Qwen35LayerCache) -> MLXArray {
        let e = preEmbedNorm(embeds), h = preHiddenNorm(hidden)
        let joined = embeddingFirst ? concatenated([e, h], axis: -1) : concatenated([h, e], axis: -1)
        let x = MLX.matmul(joined, fc.transposed())
        let L = x.shape[1]
        let mask = Qwen35ForCausalLM.attentionMask(length: L, offset: cache.offset)
        let l = layer(x, mask: mask, cache: cache)
        return norm(l)
    }
}

extension LocalMLXProvider {
    /// How often the MTP head's guess matches what the main model actually generates. Runs the main
    /// model greedily for `count` tokens after `messages`, then replays the whole sequence through both
    /// and compares, for each way of wiring the head that the checkpoint format leaves open.
    public func debugMTPProbe(messages: [Message], count: Int, mtpFile: URL)
        async throws -> [(variant: String, matched: Int, total: Int)]
    {
        let (mdl, tok) = try await ensureLoaded()
        let text = ChatPromptRenderer.render(messages).text
        var ids = tok.encode(text: text, addSpecialTokens: false).map { Int32($0) }
        let promptCount = ids.count

        // Greedy continuation with the normal decode path.
        let cache = mdl.makeCache()
        mdl.prefill(MLXArray(Array(ids.dropLast()))[.newAxis], cache: cache)
        MLX.eval(cache.stateArrays)
        var current = ids[ids.count - 1]
        for _ in 0..<count {
            let logits = mdl(MLXArray([current])[.newAxis], cache: cache)
            let next = argMax(logits, axis: -1).item(Int32.self)
            if next == 248046 || next == 248044 { break }
            ids.append(next)
            current = next
        }
        let n = ids.count
        guard n - promptCount >= 8 else { return [] }

        let hidden = mdl.hiddenStates(MLXArray(ids)[.newAxis], cache: mdl.makeCache())   // [1, N, H]
        let mtp = Qwen35MTP(weights: WeightStore(try Qwen35MTP.loadTensors(from: mtpFile),
                                                 quant: loadQuantConfigForProbe()),
                            config: try loadConfigForProbe())
        // Head at position t reads hidden_t and the embedding of token t+e, and is scored against token t+g.
        // The published convention is e = 1, g = 2; the grid checks the neighbours in case it differs.
        var out: [(String, Int, Int)] = []
        for e in [0, 1] {
            for g in [1, 2] {
                let last = n - 1 - max(e, g)                               // last usable position t
                let embeds = mdl.embed(MLXArray(Array(ids[e...(last + e)]))[.newAxis])
                // The head reads the final-normed hidden state (the final norm has per-channel weights, so
                // this is not interchangeable with the raw one).
                let hs = mdl.finalNorm(hidden[0..., 0...last])
                for embeddingFirst in [true, false] {
                    let y = mtp(embeds: embeds, hidden: hs, embeddingFirst: embeddingFirst, cache: Qwen35LayerCache())
                    let first = promptCount - 1                             // score only generated text
                    let region = y[0..., first...last]
                    let guess = argMax(mdl.logits(fromNormed: region), axis: -1)[0]
                    let actual = MLXArray(Array(ids[(first + g)...(last + g)]))
                    let matched = (guess .== actual).sum().item(Int.self)
                    out.append(("embed t+\(e), target t+\(g), \(embeddingFirst ? "emb first" : "hidden first")", matched, actual.shape[0]))
                }
            }
        }
        return out
    }
}
