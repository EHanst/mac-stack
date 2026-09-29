import MLX
import MLXNN

// MARK: - Walsh-Hadamard Transform helpers

/// Forward WHT: multiply signs then apply blockwise Hadamard (for linear input rotation).
/// x last dim must be divisible by block; block must be a power of 2.
func prismFWHT(_ x: MLXArray, block: Int, signs: MLXArray?) -> MLXArray {
    let scale = 1.0 / Float(block).squareRoot()
    let shape = x.shape
    let n = shape[shape.count - 1]
    let nBlocks = n / block
    let blocked = (signs != nil ? x.asType(.float32) * signs! : x.asType(.float32))
        .reshaped(Array(shape.dropLast()) + [nBlocks, block])
    return hadamardTransform(blocked, scale: scale).reshaped(shape).asType(x.dtype)
}

/// Inverse WHT: apply blockwise Hadamard then multiply signs (for embedding dequant).
func prismIFWHT(_ x: MLXArray, block: Int, signs: MLXArray?) -> MLXArray {
    let scale = 1.0 / Float(block).squareRoot()
    let shape = x.shape
    let n = shape[shape.count - 1]
    let nBlocks = n / block
    let blocked = x.asType(.float32).reshaped(Array(shape.dropLast()) + [nBlocks, block])
    let out = hadamardTransform(blocked, scale: scale).reshaped(shape)
    return (signs != nil ? out * signs! : out).asType(x.dtype)
}

// MARK: - PrismPackedLinear

/// Ternary-quantized linear layer (2-bit packed uint32) with optional input WHT rotation.
final class PrismPackedLinear: Module, UnaryLayer, @unchecked Sendable {
    /// Quantized weight: (outFeatures, inFeatures/16) uint32
    let weight: MLXArray
    /// Affine scale per group: (outFeatures, inFeatures/128) float16
    let scales: MLXArray
    /// Affine bias per group: (outFeatures, inFeatures/128) float16
    let biases: MLXArray
    /// WHT block size (0 = no rotation)
    let block: Int
    /// Per-element signs ±1 applied before WHT, shape (1, inFeatures) or (inFeatures,)
    let signs: MLXArray?

    init(weight: MLXArray, scales: MLXArray, biases: MLXArray,
         block: Int = 0, signs: MLXArray? = nil) {
        self.weight = weight
        self.scales = scales
        self.biases = biases
        self.block = block
        self.signs = signs
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let inp = block > 0 ? prismFWHT(x, block: block, signs: signs) : x
        return quantizedMatmul(inp, weight, scales: scales, biases: biases,
                               transpose: true, groupSize: 128, bits: 2)
    }

    /// True when both layers rotate their input identically (same block size and the very
    /// same sign vector), so they can share one rotated input.
    func sharesRotation(with other: PrismPackedLinear) -> Bool {
        block == other.block && signs === other.signs
    }
}

// MARK: - WeightStore

/// Loaded tensors that can be consumed. Fusing projections concatenates several tensors into
/// one; `take` drops the originals as it goes so peak memory stays at ~one layer of overhead
/// instead of holding both the fused and unfused copies of most of the model.
final class WeightStore: @unchecked Sendable {
    private var tensors: [String: MLXArray]

    init(_ tensors: [String: MLXArray]) { self.tensors = tensors }

    subscript(key: String) -> MLXArray? { tensors[key] }

    func take(_ key: String) -> MLXArray? { tensors.removeValue(forKey: key) }
}

// MARK: - PrismFusedLinear

/// Several packed projections that read the same input, run as one quantized matmul.
///
/// Packed weights, scales and biases are all laid out `[out, ...]` with quantization groups
/// along the input dimension, so stacking projections along axis 0 is exact. One dispatch and
/// one Hadamard rotation replace N of each (q/k/v, gate/up, linear-attn qkv/z), which matters
/// for single-token decode where per-op overhead rivals the weight-streaming time.
final class PrismFusedLinear: Module, @unchecked Sendable {
    let linear: PrismPackedLinear
    private let splitPoints: [Int]

    /// `prefixes` name the projections (e.g. `model.layers.3.self_attn.q_proj`); their
    /// tensors are consumed from `store`.
    init(store: WeightStore, prefixes: [String], hadamard: HadamardMeta) {
        var ws: [MLXArray] = [], ss: [MLXArray] = [], bs: [MLXArray] = []
        var sizes: [Int] = []
        var rotation: (block: Int, signs: MLXArray?)?
        for p in prefixes {
            let r = hadamard.rotation(for: p)
            if let first = rotation {
                precondition(first.block == r.block && first.signs === r.signs,
                             "Fused projections must share an input rotation: \(p)")
            } else {
                rotation = r
            }
            let w = store.take("\(p).weight")!
            ws.append(w)
            ss.append(store.take("\(p).scales")!)
            bs.append(store.take("\(p).biases")!)
            sizes.append(w.shape[0])
        }
        let fw = concatenated(ws, axis: 0)
        let fs = concatenated(ss, axis: 0)
        let fb = concatenated(bs, axis: 0)
        // Materialise now so the source tensors can be freed before the next layer loads.
        MLX.eval(fw, fs, fb)
        linear = PrismPackedLinear(weight: fw, scales: fs, biases: fb,
                                   block: rotation?.block ?? 0, signs: rotation?.signs)
        var acc = 0
        splitPoints = sizes.dropLast().map { acc += $0; return acc }
        super.init()
    }

    /// Outputs of each fused projection, in `prefixes` order.
    func callAsFunction(_ x: MLXArray) -> [MLXArray] {
        MLX.split(linear(x), indices: splitPoints, axis: -1)
    }
}

// MARK: - PrismPackedEmbedding

/// Ternary-quantized embedding table with optional output inverse-WHT rotation.
final class PrismPackedEmbedding: Module, @unchecked Sendable {
    /// Quantized embedding rows: (vocabSize, hiddenSize/16) uint32
    let weight: MLXArray
    let scales: MLXArray
    let biases: MLXArray
    let block: Int
    let signs: MLXArray?

    init(weight: MLXArray, scales: MLXArray, biases: MLXArray,
         block: Int = 0, signs: MLXArray? = nil) {
        self.weight = weight
        self.scales = scales
        self.biases = biases
        self.block = block
        self.signs = signs
        super.init()
    }

    /// Lookup embeddings by index.
    ///
    /// Gathers the packed rows (and their scales/biases) first and dequantizes only those,
    /// instead of dequantizing the entire vocab × hidden table on every forward pass.
    func callAsFunction(_ indices: MLXArray) -> MLXArray {
        let rows = dequantized(weight[indices], scales: scales[indices], biases: biases[indices],
                               groupSize: 128, bits: 2)
        return block > 0 ? prismIFWHT(rows, block: block, signs: signs) : rows
    }

    /// Use embedding weight as LM head (same rotation convention as linear forward).
    func asLMHead(_ x: MLXArray) -> MLXArray {
        let inp = block > 0 ? prismFWHT(x, block: block, signs: signs) : x
        return quantizedMatmul(inp, weight, scales: scales, biases: biases,
                               transpose: true, groupSize: 128, bits: 2)
    }
}
