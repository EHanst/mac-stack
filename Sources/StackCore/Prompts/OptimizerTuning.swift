import Foundation

/// Settings for the rewrite request that depend on which local model answers it. Each model gets its own,
/// measured on its own eval run, so tuning one never shifts another: `standard` is the 4B-tuned baseline and
/// what every model without an entry here (cloud included) uses.
public struct OptimizerTuning: Sendable, Equatable {
    public var sampling: SamplingParameters
    /// Extra rules appended to the rewrite request, per mode, for a model that needs steering the baseline doesn't.
    public var extraRules: [OptimizeMode: String]

    /// Hard ceiling on the reply per mode, for a model that can fall into a repetition loop. A reply that hits it
    /// is rejected as too big and the user's draft is kept, instead of waiting out the whole context.
    public var replyCap: [OptimizeMode: Int]

    public init(sampling: SamplingParameters = .rewrite, extraRules: [OptimizeMode: String] = [:],
                replyCap: [OptimizeMode: Int] = [:]) {
        self.sampling = sampling
        self.extraRules = extraRules
        self.replyCap = replyCap
    }

    public static let standard = OptimizerTuning()

    /// Qwen3.5-9B writes about a quarter more than the 4B and adds sections the request never asked for.
    public static let qwen35_9b = OptimizerTuning(extraRules: [
        .adapt: "Add nothing the draft does not say.",
        .improve: "State each requirement once, and leave out any section the request gives nothing for.",
        .expand: "State each requirement once, and leave out any section the request gives nothing for.",
    ], replyCap: [.adapt: 600])

    /// The tuning for the model that will answer, recognised by its provider id (`local:<folder>`).
    public static func forModel(_ id: ProviderID?) -> OptimizerTuning {
        guard let id = id?.lowercased(), id.hasPrefix("local:") else { return .standard }
        if id.contains("qwen3.5-9b") { return .qwen35_9b }
        return .standard
    }
}
