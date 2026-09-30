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

    /// `[1, vocab]` marker of `token` for the presence penalty.
    public static func oneHot(_ token: MLXArray, vocab: Int) -> MLXArray {
        (MLXArray(Int32(0) ..< Int32(vocab))[.newAxis] .== token.reshaped([1, 1]).asType(.int32)).asType(.float32)
    }
}
