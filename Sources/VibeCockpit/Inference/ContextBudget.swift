import Foundation

/// How much prompt the local model can take on this Mac right now without risking a Metal
/// out-of-memory abort (which kills the whole process — it is not a catchable Swift error).
///
/// Peak GPU memory during a request is modelled as
///     weights + fixedOverhead + bytesPerToken × promptTokens
/// where `fixedOverhead` covers prefill activations for one chunk, and `bytesPerToken` covers
/// the KV cache plus copy-on-write snapshot copies. Both are measured with `VibeBench --sweep`
/// (see docs/plans/m0-status.md) rather than derived, and re-measured when the model changes.
public struct ContextBudget: Sendable, Equatable {

    public struct Model: Sendable, Equatable {
        public var fixedOverheadBytes: Int
        public var bytesPerToken: Int
        public init(fixedOverheadBytes: Int, bytesPerToken: Int) {
            self.fixedOverheadBytes = fixedOverheadBytes
            self.bytesPerToken = bytesPerToken
        }
    }

    /// Fraction of the GPU working set we allow ourselves to use; the rest is slack for other
    /// processes' GPU allocations and measurement error.
    public var safetyFraction: Double
    /// Never claim more than the model's own context window.
    public var contextWindow: Int
    /// Below this the local model is not useful (system prompt + a short chat won't fit).
    public var minimumUsefulTokens: Int
    public var model: Model

    public init(model: Model, safetyFraction: Double = 0.85,
                contextWindow: Int = 64_000, minimumUsefulTokens: Int = 2_048) {
        self.model = model
        self.safetyFraction = safetyFraction
        self.contextWindow = contextWindow
        self.minimumUsefulTokens = minimumUsefulTokens
    }

    public enum Verdict: Sendable, Equatable {
        case ok(maxPromptTokens: Int)
        /// Not enough memory for a useful local context; use cloud-only mode.
        case belowFloor(maxPromptTokens: Int)
    }

    /// - Parameters:
    ///   - workingSetBytes: `GPU.maxRecommendedWorkingSetBytes()`.
    ///   - weightBytes: model weights (resident, or about to be).
    ///   - currentActiveBytes: what this process already holds on the GPU (0 before load).
    ///   - availableSystemBytes: memory the system can still hand out (free + reclaimable).
    ///     Other apps' GPU use — Ollama, other MLX apps — shows up here as *less available*.
    public func verdict(
        workingSetBytes: Int, weightBytes: Int,
        currentActiveBytes: Int = 0, availableSystemBytes: Int? = nil
    ) -> Verdict {
        let base = weightBytes + model.fixedOverheadBytes
        var room = Int(Double(workingSetBytes) * safetyFraction) - base
        if let available = availableSystemBytes {
            // We may still take `available`; memory we already hold counts toward `base`.
            room = min(room, Int(Double(available) * safetyFraction) + currentActiveBytes - base)
        }
        let tokens = room > 0 && model.bytesPerToken > 0 ? room / model.bytesPerToken : 0
        let capped = min(tokens, contextWindow)
        return capped >= minimumUsefulTokens
            ? .ok(maxPromptTokens: capped)
            : .belowFloor(maxPromptTokens: max(0, capped))
    }

    /// Predicted peak for a prompt of `promptTokens`.
    public func predictedPeakBytes(weightBytes: Int, promptTokens: Int) -> Int {
        weightBytes + model.fixedOverheadBytes + model.bytesPerToken * promptTokens
    }
}

extension ContextBudget {
    /// Ternary-Bonsai-2-27B (2-bit MLX) with 128-token prefill chunks, M3 Pro 18 GB.
    /// Fit to `VibeBench --sweep` (docs/plans/m0-status.md): measured peak over weights was
    /// 1.72 / 1.88 / 2.12 / 2.72 GiB at 1,042 / 2,088 / 4,175 / 8,421 prompt tokens; this
    /// model predicts each of those slightly high (conservative).
    public static let bonsai27B2bit = ContextBudget(
        model: Model(fixedOverheadBytes: 1_717_986_918 /* 1.6 GiB */, bytesPerToken: 165_000))
}
