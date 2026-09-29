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
        apply(preRotated: rotate(x))
    }

    /// Apply the input-side Walsh-Hadamard rotation (identity when `block == 0`).
    func rotate(_ x: MLXArray) -> MLXArray {
        block > 0 ? prismFWHT(x, block: block, signs: signs) : x
    }

    /// Packed 2-bit matmul on an input that has already been rotated by `rotate(_:)`.
    func apply(preRotated x: MLXArray) -> MLXArray {
        quantizedMatmul(x, weight, scales: scales, biases: biases,
                        transpose: true, groupSize: 128, bits: 2)
    }

    /// True when both layers rotate their input identically (same block size and the very
    /// same sign vector), so a single rotated copy of `x` can feed both.
    func sharesRotation(with other: PrismPackedLinear) -> Bool {
        block == other.block && signs === other.signs
    }

    /// Project `x` through several layers, computing each distinct input rotation only once.
    ///
    /// Q/K/V, gate/up and the linear-attention input projections all read the same
    /// activations with the same rotation; without this the WHT (fp32 cast, sign multiply,
    /// Hadamard, cast back) runs once per projection on every token of every layer.
    static func project(_ x: MLXArray, _ layers: PrismPackedLinear...) -> [MLXArray] {
        var rotated: [(layer: PrismPackedLinear, value: MLXArray)] = []
        return layers.map { layer in
            if let hit = rotated.first(where: { $0.layer.sharesRotation(with: layer) }) {
                return layer.apply(preRotated: hit.value)
            }
            let r = layer.rotate(x)
            rotated.append((layer, r))
            return layer.apply(preRotated: r)
        }
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
