import Foundation

/// User-facing privacy switch. Ordered from most private to most permissive.
public enum RoutingPolicy: String, Sendable, Codable, CaseIterable {
    /// Never send anything off this Mac.
    case localOnly
    /// Prefer local; use cloud only when no local provider can serve the request.
    case localFirst
    /// Cloud may be chosen proactively (context too large, memory pressure).
    case cloudAllowed
}

public struct RoutingRequest: Sendable {
    public var task: InferenceTask
    public var estimatedTokens: Int
    /// Largest prompt the local model can take right now (nil = unknown/unbounded).
    public var localContextLimit: Int?
    public var underMemoryPressure: Bool

    public init(
        task: InferenceTask,
        estimatedTokens: Int = 0,
        localContextLimit: Int? = nil,
        underMemoryPressure: Bool = false
    ) {
        self.task = task
        self.estimatedTokens = estimatedTokens
        self.localContextLimit = localContextLimit
        self.underMemoryPressure = underMemoryPressure
    }
}

/// Point-in-time view of a provider; keeps `Router` pure and testable.
public struct RouteCandidate: Sendable, Equatable {
    public let id: ProviderID
    public let capabilities: ProviderCapabilities
    public let isLocal: Bool
    public let health: ProviderHealth

    public init(id: ProviderID, capabilities: ProviderCapabilities, isLocal: Bool, health: ProviderHealth) {
        self.id = id
        self.capabilities = capabilities
        self.isLocal = isLocal
        self.health = health
    }
}

public enum Router {

    /// Ordered provider IDs to try. The caller walks the list, falling through on failure.
    /// An empty result means the request cannot be served under the current policy.
    public static func plan(
        policy: RoutingPolicy,
        request: RoutingRequest,
        candidates: [RouteCandidate]
    ) -> [ProviderID] {
        let required = requiredCapability(for: request.task)
        let usable = candidates
            .filter { $0.capabilities.contains(required) }
            .filter { if case .unavailable = $0.health { return false } else { return true } }
            .sorted { $0.id < $1.id }

        let local = usable.filter(\.isLocal).map(\.id)
        let cloud = usable.filter { !$0.isLocal }.map(\.id)

        switch policy {
        case .localOnly:
            return local
        case .localFirst:
            return local + cloud
        case .cloudAllowed:
            let tooBig = request.localContextLimit.map { request.estimatedTokens > $0 } ?? false
            return (tooBig || request.underMemoryPressure) ? cloud + local : local + cloud
        }
    }

    static func requiredCapability(for task: InferenceTask) -> ProviderCapabilities {
        switch task {
        case .textGeneration: .textGeneration
        case .embedding: .embedding
        case .speculativeDraft: .speculativeDraft
        }
    }
}

extension ModelProvider {
    /// Local providers are registered as `local:<name>`; everything else is cloud.
    public nonisolated var isLocal: Bool { id.hasPrefix("local:") }
}

extension ModelRegistry {
    /// Ordered provider IDs for a request under `policy`.
    public func route(policy: RoutingPolicy, request: RoutingRequest) async -> [ProviderID] {
        var candidates: [RouteCandidate] = []
        for provider in allProviders {
            candidates.append(RouteCandidate(
                id: provider.id,
                capabilities: provider.capabilities,
                isLocal: provider.isLocal,
                health: await provider.healthCheck()))
        }
        return Router.plan(policy: policy, request: request, candidates: candidates)
    }
}
