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
    let spec: QuantSpec

    init(weight: MLXArray, scales: MLXArray, biases: MLXArray,
         block: Int = 0, signs: MLXArray? = nil, spec: QuantSpec = .bonsai) {
        self.weight = weight
        self.scales = scales
        self.biases = biases
        self.block = block
        self.signs = signs
        self.spec = spec
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let inp = block > 0 ? prismFWHT(x, block: block, signs: signs) : x
        return quantizedMatmul(inp, weight, scales: scales, biases: biases,
                               transpose: true, groupSize: spec.groupSize, bits: spec.bits)
    }

    /// True when both layers rotate their input identically (same block size and the very
    /// same sign vector), so they can share one rotated input.
    func sharesRotation(with other: PrismPackedLinear) -> Bool {
        block == other.block && signs === other.signs
    }
}

// MARK: - Quantization config

/// Bit width and group size of one quantized tensor.
struct QuantSpec: Equatable, Sendable {
    var bits: Int
    var groupSize: Int
    /// The Bonsai pack: 2-bit, group 128.
    static let bonsai = QuantSpec(bits: 2, groupSize: 128)
}

/// Per-module quantization from `config.json`'s `quantization` block: a default plus optional
/// per-module overrides (mixed-precision packs such as OptiQ keep sensitive layers at 8-bit).
/// Override keys are stripped of the `language_model.` prefix to match `WeightStore` keys.
struct QuantConfig: Sendable {
    var fallback: QuantSpec = .bonsai
    var overrides: [String: QuantSpec] = [:]

    func spec(for prefix: String) -> QuantSpec { overrides[prefix] ?? fallback }

    init(fallback: QuantSpec = .bonsai, overrides: [String: QuantSpec] = [:]) {
        self.fallback = fallback
        self.overrides = overrides
    }

    init(configDict dict: [String: Any]) {
        guard let q = dict["quantization"] as? [String: Any] else { self.init(); return }
        let base = QuantSpec(bits: q["bits"] as? Int ?? QuantSpec.bonsai.bits,
                             groupSize: q["group_size"] as? Int ?? QuantSpec.bonsai.groupSize)
        var ov: [String: QuantSpec] = [:]
        let lm = "language_model."
        for (key, value) in q {
            guard let d = value as? [String: Any], let bits = d["bits"] as? Int else { continue }
            let name = key.hasPrefix(lm) ? String(key.dropFirst(lm.count)) : key
            ov[name] = QuantSpec(bits: bits, groupSize: d["group_size"] as? Int ?? base.groupSize)
        }
        self.init(fallback: base, overrides: ov)
    }
}

// MARK: - WeightStore

/// Loaded tensors that can be consumed. Fusing projections concatenates several tensors into
/// one; `take` drops the originals as it goes so peak memory stays at ~one layer of overhead
/// instead of holding both the fused and unfused copies of most of the model.
final class WeightStore: @unchecked Sendable {
    private var tensors: [String: MLXArray]
    let quant: QuantConfig

    init(_ tensors: [String: MLXArray], quant: QuantConfig = QuantConfig()) {
        self.tensors = tensors
        self.quant = quant
    }

    /// The quantized projection at `prefix` (`<prefix>.weight/.scales/.biases`), read in place.
    func packedLinear(_ prefix: String, hadamard: HadamardMeta) -> PrismPackedLinear {
        let (b, s) = hadamard.rotation(for: prefix)
        return PrismPackedLinear(
            weight: self["\(prefix).weight"]!, scales: self["\(prefix).scales"]!,
            biases: self["\(prefix).biases"]!, block: b, signs: s, spec: quant.spec(for: prefix))
    }

    /// A small matrix as float: dequantized when the pack quantized it, raw otherwise.
    func dense(_ prefix: String) -> MLXArray {
        guard let s = self["\(prefix).scales"], let b = self["\(prefix).biases"] else {
            return self["\(prefix).weight"]!
        }
        let spec = quant.spec(for: prefix)
        return dequantized(self["\(prefix).weight"]!, scales: s, biases: b,
                           groupSize: spec.groupSize, bits: spec.bits)
    }

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
    /// One fused matmul per run of consecutive projections that share quantization and input
    /// rotation (a mixed-precision pack may split q/k/v into several runs).
    private let linears: [PrismPackedLinear]
    private let splitPoints: [[Int]]

    /// `prefixes` name the projections (e.g. `model.layers.3.self_attn.q_proj`); their
    /// tensors are consumed from `store`.
    init(store: WeightStore, prefixes: [String], hadamard: HadamardMeta) {
        struct Run {
            var ws: [MLXArray] = [], ss: [MLXArray] = [], bs: [MLXArray] = []
            var sizes: [Int] = []
            var spec: QuantSpec
            var rotation: (block: Int, signs: MLXArray?)
        }
        var runs: [Run] = []
        for p in prefixes {
            let r = hadamard.rotation(for: p)
            let spec = store.quant.spec(for: p)
            if runs.last.map({ $0.spec != spec || $0.rotation.block != r.block
                                 || $0.rotation.signs !== r.signs }) ?? true {
                runs.append(Run(spec: spec, rotation: r))
            }
            let w = store.take("\(p).weight")!
            runs[runs.count - 1].ws.append(w)
            runs[runs.count - 1].ss.append(store.take("\(p).scales")!)
            runs[runs.count - 1].bs.append(store.take("\(p).biases")!)
            runs[runs.count - 1].sizes.append(w.shape[0])
        }
        var linears: [PrismPackedLinear] = []
        var splits: [[Int]] = []
        for run in runs {
            let fw = concatenated(run.ws, axis: 0)
            let fs = concatenated(run.ss, axis: 0)
            let fb = concatenated(run.bs, axis: 0)
            // Materialise now so the source tensors can be freed before the next layer loads.
            MLX.eval(fw, fs, fb)
            linears.append(PrismPackedLinear(weight: fw, scales: fs, biases: fb,
                                             block: run.rotation.block, signs: run.rotation.signs,
                                             spec: run.spec))
            var acc = 0
            splits.append(run.sizes.dropLast().map { acc += $0; return acc })
        }
        self.linears = linears
        self.splitPoints = splits
        super.init()
    }

    /// Outputs of each fused projection, in `prefixes` order.
    func callAsFunction(_ x: MLXArray) -> [MLXArray] {
        var out: [MLXArray] = []
        for (linear, split) in zip(linears, splitPoints) {
            let y = linear(x)
            out += split.isEmpty ? [y] : MLX.split(y, indices: split, axis: -1)
        }
        return out
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
    let spec: QuantSpec

    init(weight: MLXArray, scales: MLXArray, biases: MLXArray,
         block: Int = 0, signs: MLXArray? = nil, spec: QuantSpec = .bonsai) {
        self.weight = weight
        self.scales = scales
        self.biases = biases
        self.block = block
        self.signs = signs
        self.spec = spec
        super.init()
    }

    /// Lookup embeddings by index.
    ///
    /// Gathers the packed rows (and their scales/biases) first and dequantizes only those,
    /// instead of dequantizing the entire vocab × hidden table on every forward pass.
    func callAsFunction(_ indices: MLXArray) -> MLXArray {
        let rows = dequantized(weight[indices], scales: scales[indices], biases: biases[indices],
                               groupSize: spec.groupSize, bits: spec.bits)
        return block > 0 ? prismIFWHT(rows, block: block, signs: signs) : rows
    }

    /// Use embedding weight as LM head (same rotation convention as linear forward).
    func asLMHead(_ x: MLXArray) -> MLXArray {
        let inp = block > 0 ? prismFWHT(x, block: block, signs: signs) : x
        return quantizedMatmul(inp, weight, scales: scales, biases: biases,
                               transpose: true, groupSize: spec.groupSize, bits: spec.bits)
    }
}
