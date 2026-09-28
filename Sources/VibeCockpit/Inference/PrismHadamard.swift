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
    func callAsFunction(_ indices: MLXArray) -> MLXArray {
        let rows = dequantized(weight, scales: scales, biases: biases, groupSize: 128, bits: 2)[indices]
        return block > 0 ? prismIFWHT(rows, block: block, signs: signs) : rows
    }

    /// Use embedding weight as LM head (same rotation convention as linear forward).
    func asLMHead(_ x: MLXArray) -> MLXArray {
        let inp = block > 0 ? prismFWHT(x, block: block, signs: signs) : x
        return quantizedMatmul(inp, weight, scales: scales, biases: biases,
                               transpose: true, groupSize: 128, bits: 2)
    }
}
