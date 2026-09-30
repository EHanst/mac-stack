import Foundation
import MLX
import MLXRandom

/// How the next token is chosen.
public struct SamplingParameters: Sendable, Equatable {
    public var temperature: Double
    /// Keep only the K most likely tokens (0 = off).
    public var topK: Int
    /// Keep the smallest set of tokens whose probability reaches P (1 = off).
    public var topP: Double
    /// Flat penalty subtracted from the logit of every token already generated this reply.
    public var presencePenalty: Double

    public init(temperature: Double, topK: Int = 0, topP: Double = 1, presencePenalty: Double = 0) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.presencePenalty = presencePenalty
    }

    public var isGreedy: Bool { temperature <= 0 }

    public static let greedy = SamplingParameters(temperature: 0)

    /// Ternary-Bonsai model card, "Instruct (or non-thinking) mode". This is what the chat uses,
    /// because the prompt asks the model to skip its reasoning block (`<think>\n\n</think>`).
    public static let bonsaiInstruct = SamplingParameters(temperature: 0.7, topK: 20, topP: 0.8, presencePenalty: 1.5)

    /// Prompt rewrites and other tasks that must reproduce text faithfully: near-deterministic and no
    /// presence penalty (which would push the model off repeating the paths, quotes and identifiers the
    /// rewrite has to keep). Measured on the rewrite eval: no fewer rewrites accepted than the chat
    /// settings, about 13% fewer tokens, and repeatable.
    public static let rewrite = SamplingParameters(temperature: 0.2, topK: 20, topP: 1, presencePenalty: 0)

    /// Ternary-Bonsai model card, "Thinking mode".
    public static let bonsaiThinking = SamplingParameters(temperature: 1.0, topK: 20, topP: 0.95, presencePenalty: 0)
}

/// GPU sampling with lazy MLX ops, so it stays inside the pipelined decode loop.
public enum TokenSampler {

    /// - Parameters:
    ///   - logits: `[1, vocab]`.
    ///   - seen: `[1, vocab]` of 0/1 marking tokens already generated (only read when a presence
    ///     penalty is set).
    /// - Returns: token id, shape `[1]`.
    public static func sample(_ logits: MLXArray, _ p: SamplingParameters, seen: MLXArray?) -> MLXArray {
        var l = logits.asType(.float32)
        if p.presencePenalty != 0, let seen { l = l - Float(p.presencePenalty) * seen }
        if p.isGreedy { return argMax(l, axis: -1) }

        let vocab = l.dim(-1)
        let k = p.topK > 0 ? min(p.topK, vocab) : 0
        let candidates: MLXArray       // token ids, most likely first
        let values: MLXArray           // their logits, same order
        if k > 0 {
            let part = argPartition(-l, kth: k - 1, axis: -1)[.ellipsis, 0 ..< k]   // K largest, unordered
            let v = takeAlong(l, part, axis: -1)
            let order = argSort(-v, axis: -1)
            candidates = takeAlong(part, order, axis: -1)
            values = takeAlong(v, order, axis: -1)
        } else if p.topP < 1 {
            let order = argSort(-l, axis: -1)
            candidates = order
            values = takeAlong(l, order, axis: -1)
        } else {
            return MLXRandom.categorical(l * (1 / Float(p.temperature)))
        }

        var probs = softmax(values * (1 / Float(p.temperature)), axis: -1)
        if p.topP < 1 {
            // Drop tokens once the probability *before* them already reaches P (the top token stays).
            let before = cumsum(probs, axis: -1) - probs
            probs = MLX.where(before .< Float(p.topP), probs, MLXArray(Float(0)))
        }
        let pick = MLXRandom.categorical(log(probs))                          // [1]
        return takeAlong(candidates, pick.expandedDimensions(axis: -1), axis: -1).squeezed(axis: -1)
    }

    /// The distribution `sample` draws from, as its `topK` candidates and their probabilities (`[rows, K]`,
    /// most likely first, summing to 1). Needs `topK > 0` and a non-greedy temperature.
    public static func distribution(_ logits: MLXArray, _ p: SamplingParameters, seen: MLXArray?)
        -> (candidates: MLXArray, probs: MLXArray)
    {
        var l = logits.asType(.float32)       // [rows, vocab]
        if p.presencePenalty != 0, let seen { l = l - Float(p.presencePenalty) * seen }
        let k = min(p.topK, l.dim(-1))
        let part = argPartition(-l, kth: k - 1, axis: -1)[.ellipsis, 0 ..< k]
        let v = takeAlong(l, part, axis: -1)
        let order = argSort(-v, axis: -1)
        let candidates = takeAlong(part, order, axis: -1)
        var probs = softmax(takeAlong(v, order, axis: -1) * (1 / Float(p.temperature)), axis: -1)
        if p.topP < 1 {
            let before = cumsum(probs, axis: -1) - probs
            probs = MLX.where(before .< Float(p.topP), probs, MLXArray(Float(0)))
            probs = probs / probs.sum(axis: -1, keepDims: true)
        }
        return (candidates.asType(.int32), probs)
    }

    /// `[1, vocab]` marker of `token` for the presence penalty.
    public static func oneHot(_ token: MLXArray, vocab: Int) -> MLXArray {
        (iota(vocab)[.newAxis] .== token.reshaped([1, 1]).asType(.int32)).asType(.float32)
    }

    /// `0 ..< vocab` on the GPU, built once. Rebuilding it per token copied 1 MB from the CPU every step
    /// (about 20 ms, most of a decode step with the presence penalty on).
    private static func iota(_ vocab: Int) -> MLXArray {
        iotaLock.lock(); defer { iotaLock.unlock() }
        if let cached = iotaCache[vocab] { return cached }
        let made = MLXArray(Int32(0) ..< Int32(vocab))
        MLX.eval(made)
        iotaCache[vocab] = made
        return made
    }
    private static let iotaLock = NSLock()
    nonisolated(unsafe) private static var iotaCache: [Int: MLXArray] = [:]
}

/// The accept/reject rule for a draft token that is a point mass (the MTP head's argmax). Accepting it with
/// probability p(draft) and otherwise drawing from p without it reproduces p exactly.
public enum SpeculativeRule {
    public typealias Distribution = (candidates: [Int32], probs: [Float])

    public static func acceptanceProbability(draft: Int, in d: Distribution) -> Float {
        d.candidates.firstIndex(of: Int32(draft)).map { d.probs[$0] } ?? 0
    }

    /// Draw from `d` (optionally with one token removed and the rest renormalised); `u` is uniform in [0, 1).
    public static func draw(_ d: Distribution, excluding: Int? = nil, u: Float) -> Int {
        var w = d.probs
        if let x = excluding, let at = d.candidates.firstIndex(of: Int32(x)) { w[at] = 0 }
        let total = w.reduce(0, +)
        guard total > 0 else { return Int(d.candidates[0]) }
        var r = u * total
        for (i, x) in w.enumerated() { r -= x; if r < 0 { return Int(d.candidates[i]) } }
        return Int(d.candidates[w.count - 1])
    }
}
