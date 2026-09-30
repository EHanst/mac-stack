import MLX

// MARK: - Per-layer cache

/// Decoding state for one decoder layer.
///
/// Full-attention layers keep a preallocated key/value buffer that grows in `step`-sized
/// blocks and is updated in place with a slice write, so appending a token is O(1) instead of
/// re-concatenating the entire history on every step of every layer.
///
/// Linear-attention layers keep the recurrent state matrix plus the trailing inputs of the
/// causal depthwise convolution (`kernelSize - 1` rows), which the convolution needs to see
/// across chunk and decode-step boundaries.
final class Qwen35LayerCache: @unchecked Sendable {
    static let step = 256

    // Full attention
    private(set) var keys: MLXArray?
    private(set) var values: MLXArray?
    private(set) var offset = 0

    // Linear attention
    var ssmState: MLXArray?
    var convState: MLXArray?
    /// Recurrent and conv state after the *first* of two tokens fed together (speculative verify), so a
    /// rejected second token can be undone. Transient: not part of `stateArrays` or `fork()`.
    var ssmStateMid: MLXArray?
    var convStateMid: MLXArray?

    /// Drop the last `n` cached key/value rows (full-attention layers); later writes overwrite them.
    func trimKV(by n: Int) { offset -= n }

    var midArrays: [MLXArray] { [ssmStateMid, convStateMid].compactMap { $0 } }

    /// Append `k`/`v` (shape `[B, nKV, L, D]`) and return views over everything cached so far.
    func updateKV(keys k: MLXArray, values v: MLXArray) -> (keys: MLXArray, values: MLXArray) {
        let previous = offset
        let n = k.shape[2]

        if keys == nil || previous + n > keys!.shape[2] {
            let B = k.shape[0], H = k.shape[1], D = k.shape[3]
            let blocks = (Self.step + n - 1) / Self.step
            let newK = MLXArray.zeros([B, H, blocks * Self.step, D], dtype: k.dtype)
            let newV = MLXArray.zeros([B, H, blocks * Self.step, v.shape[3]], dtype: v.dtype)
            if let oldK = keys, let oldV = values, previous > 0 {
                // Drop unused tail capacity before growing so it isn't carried forward.
                let usedK = previous == oldK.shape[2] ? oldK : oldK[.ellipsis, ..<previous, 0...]
                let usedV = previous == oldV.shape[2] ? oldV : oldV[.ellipsis, ..<previous, 0...]
                keys = concatenated([usedK, newK], axis: 2)
                values = concatenated([usedV, newV], axis: 2)
            } else {
                keys = newK
                values = newV
            }
        }

        offset = previous + n
        keys![.ellipsis, previous ..< offset, 0...] = k
        values![.ellipsis, previous ..< offset, 0...] = v
        return (keys![.ellipsis, ..<offset, 0...], values![.ellipsis, ..<offset, 0...])
    }

    /// Every array that must be materialised to make this cache state concrete.
    var stateArrays: [MLXArray] {
        [keys, values, ssmState, convState].compactMap { $0 }
    }

    /// An independent cache holding the same state.
    ///
    /// `MLXArray` subscript assignment replaces the array's storage in place, so sharing the
    /// same `MLXArray` object between two caches would let one corrupt the other. `asType` to
    /// the same dtype yields a distinct handle onto the same immutable buffer (no data copy);
    /// MLX copies on the first write to a shared buffer.
    func fork() -> Qwen35LayerCache {
        let c = Qwen35LayerCache()
        c.keys = keys.map { $0.asType($0.dtype) }
        c.values = values.map { $0.asType($0.dtype) }
        c.offset = offset
        c.ssmState = ssmState.map { $0.asType($0.dtype) }
        c.convState = convState.map { $0.asType($0.dtype) }
        return c
    }
}

// MARK: - Whole-model cache

/// Cache for every layer plus the number of tokens already consumed.
final class Qwen35Cache: @unchecked Sendable {
    let layers: [Qwen35LayerCache]
    private(set) var tokenCount: Int
    /// The MTP head's own key/value cache, when speculative decoding is in use.
    var mtp: Qwen35LayerCache?

    init(layerCount: Int, withMTP: Bool = false) {
        layers = (0..<layerCount).map { _ in Qwen35LayerCache() }
        tokenCount = 0
        mtp = withMTP ? Qwen35LayerCache() : nil
    }

    private init(layers: [Qwen35LayerCache], tokenCount: Int, mtp: Qwen35LayerCache?) {
        self.layers = layers
        self.tokenCount = tokenCount
        self.mtp = mtp
    }

    func advance(by n: Int) { tokenCount += n }
    func rewind(by n: Int) { tokenCount -= n }

    var stateArrays: [MLXArray] { layers.flatMap(\.stateArrays) + (mtp?.stateArrays ?? []) }
    var midArrays: [MLXArray] { layers.flatMap(\.midArrays) }

    func fork() -> Qwen35Cache {
        Qwen35Cache(layers: layers.map { $0.fork() }, tokenCount: tokenCount, mtp: mtp?.fork())
    }
}
