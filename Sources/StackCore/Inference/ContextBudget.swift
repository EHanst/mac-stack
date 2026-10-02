import Foundation

/// How much prompt the local model can take on this Mac right now without risking a Metal
/// out-of-memory abort (which kills the whole process — it is not a catchable Swift error).
///
/// Peak GPU memory during a request is modelled as
///     weights + fixedOverhead + bytesPerToken × promptTokens
/// where `fixedOverhead` covers prefill activations for one chunk, and `bytesPerToken` covers
/// the KV cache plus copy-on-write snapshot copies. Both are measured with `KokoroBench --sweep`
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
    /// Memory held by other always-loaded models (e.g. the embedder) that the model can't use.
    public var reservedBytes = 0

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
        let base = weightBytes + model.fixedOverheadBytes + reservedBytes
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
        weightBytes + model.fixedOverheadBytes + reservedBytes + model.bytesPerToken * promptTokens
    }
}

extension ContextBudget {
    /// Ternary-Bonsai-2-27B (2-bit MLX) with 128-token prefill chunks, M3 Pro 18 GB.
    /// Fit to `KokoroBench --sweep` on the *corrected* model (Gated DeltaNet fix): measured peak over
    /// weights was 1.45 / 1.57 / 1.92 / 2.46 GiB at 1,042 / 2,087 / 4,175 / 8,419 prompt tokens.
    /// This model predicts each slightly high (conservative). The slope matches the config:
    /// KV is 64 KiB/token, and a live cache plus a prefix snapshot copy is 2–3× that.
    public static let bonsai27B2bit = ContextBudget(
        model: Model(fixedOverheadBytes: 1_449_551_462 /* 1.35 GiB */, bytesPerToken: 155_000))
}

extension ContextBudget {
    /// Qwen3.5-4B (OptiQ mixed 4/8-bit) with 128-token prefill chunks, M3 Pro 18 GB. Fit to
    /// `KokoroBench --sweep`: peak GPU was 3.50 / 3.64 / 3.82 / 4.11 GiB at 1,041 / 4,175 / 8,421 / 16,861
    /// prompt tokens, a slope of about 41 KB/token. Only 8 of its 32 layers keep a KV cache (32 KiB/token).
    /// Rounded up to 0.5 GiB fixed and 64 KB/token, about 1.5× the measured slope.
    public static let qwen35_4b = ContextBudget(
        model: Model(fixedOverheadBytes: 512 << 20, bytesPerToken: 64_000))

    /// Qwen3.5-9B (OptiQ mixed 4/8-bit) with 128-token prefill chunks, M3 Pro 18 GB. Peak GPU was 7.34 GB at 528
    /// prompt tokens and 7.64 GB at 4,170, a slope of about 82 KB/token (8 of 32 layers keep a KV cache, 4 KV heads
    /// of 256). Rounded up to 0.5 GiB fixed and 128 KB/token, about 1.5× the measured slope.
    public static let qwen35_9b = ContextBudget(
        model: Model(fixedOverheadBytes: 512 << 20, bytesPerToken: 128_000))

    /// The measured budget for the model in `directory`, recognised by its shape. Anything we have not
    /// measured gets the 27B budget, the most conservative one.
    public static func forModel(at directory: URL) -> ContextBudget {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .bonsai27B2bit }
        let text = (dict["text_config"] as? [String: Any]) ?? dict
        if text["num_hidden_layers"] as? Int == 32, text["hidden_size"] as? Int == 2560 { return .qwen35_4b }
        if text["num_hidden_layers"] as? Int == 32, text["hidden_size"] as? Int == 4096 { return .qwen35_9b }
        return .bonsai27B2bit
    }
}
