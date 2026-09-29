import Foundation
import os

public enum InferenceError: LocalizedError, Equatable {
    case noProvider(RoutingPolicy)
    case unknownModel(String)
    case notAllowedByPolicy(model: String, policy: RoutingPolicy)

    public var errorDescription: String? {
        switch self {
        case .noProvider(.localOnly):
            "No local model is available. Download one, or allow cloud providers in settings."
        case .noProvider:
            "No model provider is available. Complete setup or add a provider."
        case .unknownModel(let id):
            "There is no model called '\(id)'."
        case .notAllowedByPolicy(let model, _):
            "'\(model)' would send data off this Mac, which the current privacy setting doesn't allow."
        }
    }
}

/// Reported as a request is routed, so a UI or log can show where a conversation went.
public struct RouteNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case using(ProviderID)
        case fellBack(from: ProviderID, to: ProviderID, reason: String)
    }
    public let kind: Kind
}

/// The single entry point for text generation. Adapters (app UI, HTTP API, MCP) call this and
/// never talk to providers directly, so routing policy, GPU scheduling and fallback behave the
/// same everywhere.
///
/// - Picks providers with `Router` under the current `RoutingPolicy`.
/// - Local providers run through the `InferenceScheduler` (one GPU, priorities, cancellation);
///   cloud providers do not, so a slow cloud call never blocks the local model.
/// - If a provider fails **before producing any output**, the next candidate is tried.
///   After output has started the error is passed through: half an answer can't be re-run
///   elsewhere without duplicating text.
public actor InferenceService {

    private let registry: ModelRegistry
    private let scheduler: InferenceScheduler
    private let gate: EgressGate?
    private let governor: SystemGovernor?
    private let requestLog: RequestLog?
    public private(set) var policy: RoutingPolicy
    private var noticeHandler: (@Sendable (RouteNotice) -> Void)?
    private let logger = Logger(subsystem: "com.vibecockpit", category: "InferenceService")

    public init(
        registry: ModelRegistry,
        scheduler: InferenceScheduler = InferenceScheduler(),
        policy: RoutingPolicy = .localFirst,
        gate: EgressGate? = nil,
        governor: SystemGovernor? = nil,
        requestLog: RequestLog? = nil
    ) {
        self.requestLog = requestLog
        self.gate = gate
        self.governor = governor
        self.registry = registry
        self.scheduler = scheduler
        self.policy = policy
    }

    public func setPolicy(_ policy: RoutingPolicy) {
        self.policy = policy
        if let gate { Task { await gate.setPolicy(policy) } }
    }

    public func setNoticeHandler(_ handler: (@Sendable (RouteNotice) -> Void)?) {
        noticeHandler = handler
    }

    /// Smallest prompt limit among local generation providers (nil if none report one).
    public func localContextLimit() async -> Int? {
        var limits: [Int] = []
        for provider in await registry.allProviders(with: .textGeneration) where provider.isLocal {
            if let n = await provider.maxContextTokens() { limits.append(n) }
        }
        return limits.min()
    }

    /// Rough prompt size; ~2.5 characters per token is deliberately pessimistic for code.
    public static func estimateTokens(_ messages: [Message]) -> Int {
        Int(Double(messages.reduce(0) { $0 + $1.content.count }) / 2.5)
    }

    // MARK: Models

    /// `nil`, "", "auto" and "default" mean "let VibeCockpit choose"; anything else names a model.
    public static func pin(for requested: String?) -> ProviderID? {
        guard let r = requested?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        return ["auto", "default"].contains(r.lowercased()) ? nil : r
    }

    public struct ModelListing: Sendable, Equatable {
        public let id: ProviderID
        public let isLocal: Bool
        public let capabilities: ProviderCapabilities
        public let health: ProviderHealth
    }

    /// Everything registered, with current health (for `/v1/models` and the menu).
    public func availableModels() async -> [ModelListing] {
        var out: [ModelListing] = []
        for p in await registry.allProviders {
            out.append(ModelListing(id: p.id, isLocal: p.isLocal, capabilities: p.capabilities, health: await p.healthCheck()))
        }
        return out.sorted { ($0.isLocal ? 0 : 1, $0.id) < ($1.isLocal ? 0 : 1, $1.id) }
    }

    /// An explicitly requested model. Unknown ids are an error; a cloud model is refused when the
    /// privacy setting is "Only on this Mac". No fallback: asking for a model by name means that model.
    private func pinned(_ id: ProviderID, task: InferenceTask) async throws -> [any ModelProvider] {
        guard let provider = await registry.provider(id: id),
              provider.capabilities.contains(Router.requiredCapability(for: task)) else {
            throw InferenceError.unknownModel(id)
        }
        if policy == .localOnly, !provider.isLocal {
            throw InferenceError.notAllowedByPolicy(model: id, policy: policy)
        }
        return [provider]
    }

    // MARK: Embeddings

    /// Embeddings from the best allowed provider (local first), falling back like `generate`.
    public func embed(_ texts: [String], pin: ProviderID? = nil) async throws -> (vectors: [[Float]], provider: ProviderID) {
        let candidates: [any ModelProvider]
        if let pin {
            candidates = try await pinned(pin, task: .embedding)
        } else {
            let plan = await registry.route(policy: policy, request: RoutingRequest(task: .embedding))
            var list: [any ModelProvider] = []
            for id in plan { if let p = await registry.provider(id: id) { list.append(p) } }
            guard !list.isEmpty else { throw InferenceError.noProvider(policy) }
            candidates = list
        }
        var lastError: Error?
        for (index, provider) in candidates.enumerated() {
            do { return (try await provider.embed(texts), provider.id) }
            catch {
                lastError = error
                if error is CancellationError || index == candidates.count - 1 { throw error }
            }
        }
        throw lastError ?? InferenceError.noProvider(policy)
    }

    // MARK: Generation

    public func generate(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions = GenerationOptions(),
        priority: InferenceScheduler.Priority = .interactive,
        pin: ProviderID? = nil,
        onRoute: (@Sendable (RouteNotice) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let candidates: [any ModelProvider]
        if let pin {
            candidates = try await pinned(pin, task: .textGeneration)
        } else {
            candidates = try await routedCandidates(messages: messages)
        }
        return stream(candidates, messages: messages, tools: tools, options: options, priority: priority, onRoute: onRoute)
    }

    private func routedCandidates(messages: [Message]) async throws -> [any ModelProvider] {
        let request = RoutingRequest(
            task: .textGeneration,
            estimatedTokens: Self.estimateTokens(messages),
            localContextLimit: await localContextLimit(),
            underMemoryPressure: await governor?.current.isStrained ?? false)
        let plan = await registry.route(policy: policy, request: request)
        var candidates: [any ModelProvider] = []
        for id in plan {
            if let provider = await registry.provider(id: id) { candidates.append(provider) }
        }
        guard !candidates.isEmpty else {
            // Say *why* the cloud fallback wasn't used when the only thing in the way is the monthly limit.
            if policy != .localOnly, let gate, let refusal = await gate.cloudAllowed() { throw refusal }
            throw InferenceError.noProvider(policy)
        }
        return candidates
    }

    private func stream(
        _ providers: [any ModelProvider], messages: [Message], tools: [ToolDefinition],
        options: GenerationOptions, priority: InferenceScheduler.Priority,
        onRoute: (@Sendable (RouteNotice) -> Void)?
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        let scheduler = self.scheduler
        let gate = self.gate
        let global = noticeHandler
        let notify: @Sendable (RouteNotice) -> Void = { global?($0); onRoute?($0) }
        let logger = self.logger
        let requestLog = self.requestLog
        let governor = self.governor
        let source = priority == .interactive ? "app" : (priority == .api ? "api" : "background")

        return AsyncThrowingStream { continuation in
            let task = Task {
                var failed: (id: ProviderID, error: Error)?
                for (index, provider) in providers.enumerated() {
                    if let failed {
                        logger.notice("falling back from \(failed.id, privacy: .public) to \(provider.id, privacy: .public): \(failed.error.localizedDescription, privacy: .public)")
                        notify(RouteNotice(kind: .fellBack(
                            from: failed.id, to: provider.id, reason: failed.error.localizedDescription)))
                    } else {
                        notify(RouteNotice(kind: .using(provider.id)))
                    }

                    var produced = false
                    let started = Date()
                    let load = await governor?.current
                    var firstToken: Date?
                    var completionChars = 0
                    var reported: GenerationUsage?
                    func record(_ outcome: RequestRecord.Outcome, _ error: Error?) async {
                        guard let requestLog else { return }
                        let promptTokens = reported?.promptTokens ?? Self.estimateTokens(messages)
                        let completion = reported?.completionTokens ?? max(0, completionChars / 3)
                        await requestLog.record(RequestRecord(
                            date: started, source: source, provider: provider.id, isLocal: provider.isLocal,
                            fellBackFrom: failed?.id, promptTokens: promptTokens, completionTokens: completion,
                            timeToFirstToken: firstToken.map { $0.timeIntervalSince(started) },
                            totalTime: Date().timeIntervalSince(started), outcome: outcome,
                            error: error?.localizedDescription,
                            memory: load.map { "\($0.memory)" } ?? "normal",
                            thermal: load.map { "\($0.thermal)" } ?? "nominal",
                            lowPowerMode: load?.lowPowerMode ?? false))
                    }
                    do {
                        // A cloud provider is skipped (with the reason) when the monthly limit is used up.
                        if !provider.isLocal, let gate, let refusal = await gate.cloudAllowed() { throw refusal }
                        let inner: AsyncThrowingStream<GenerationEvent, Error>
                        if provider.isLocal {
                            inner = scheduler.stream(priority: priority) {
                                await provider.generate(messages: messages, tools: tools, options: options)
                            }
                        } else {
                            inner = await provider.generate(messages: messages, tools: tools, options: options)
                        }
                        for try await event in inner {
                            produced = true
                            if case .token(let t) = event { completionChars += t.count; if firstToken == nil { firstToken = Date() } }
                            if case .usage(let u) = event { reported = u }
                            continuation.yield(event)
                        }
                        if !provider.isLocal, let gate {
                            let used = reported.map { $0.promptTokens + $0.completionTokens }
                                ?? Self.estimateTokens(messages) + max(1, completionChars / 3)
                            await gate.recordCloudTokens(used)
                        }
                        await record(.completed, nil)
                        continuation.finish()
                        return
                    } catch {
                        let cancelled = error is CancellationError || Task.isCancelled
                        await record(cancelled ? .cancelled : .failed, cancelled ? nil : error)
                        let isLast = index == providers.count - 1
                        if produced || isLast || error is CancellationError || Task.isCancelled {
                            continuation.finish(throwing: error)
                            return
                        }
                        failed = (provider.id, error)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension InferenceService {
    /// The model a chat request would go to right now (first in the routing plan), so callers can
    /// tailor a prompt to it. Nil when nothing can serve a request under the current policy.
    public func plannedModel() async -> ProviderID? {
        let request = RoutingRequest(task: .textGeneration, localContextLimit: await localContextLimit())
        return await registry.route(policy: policy, request: request).first
    }
}
