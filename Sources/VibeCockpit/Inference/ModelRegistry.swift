import Foundation
import os

/// Discovers and manages all available ModelProviders at runtime.
/// No models are assumed present — discovers local bundles and remote
/// provider configs supplied at startup.
public actor ModelRegistry {

    private var providers: [ProviderID: any ModelProvider] = [:]
    private let logger = Logger(subsystem: "com.vibecockpit", category: "ModelRegistry")

    public enum RegistryError: LocalizedError {
        case noProvidersAvailable
        case providerNotFound(ProviderID)

        public var errorDescription: String? {
            switch self {
            case .noProvidersAvailable: "No model providers are configured."
            case .providerNotFound(let id): "Provider '\(id)' is not registered."
            }
        }
    }

    public init() {}

    /// Discover providers from:
    /// 1. Local model directory (scanned for config.json bundles)
    /// 2. Remote provider configs from ~/.config/vibecockpit/providers.json
    public func discover(
        localDirectory: URL? = nil,
        remoteConfigs: [RemoteAPIProvider.Config] = [],
        credentials: CredentialStore
    ) async throws {
        if let dir = localDirectory {
            await discoverLocalModels(in: dir)
        }
        for config in remoteConfigs {
            await credentials.registerEnvVarKey(config.envVarKey, for: config.id)
            let provider = RemoteAPIProvider(config: config, credentials: credentials)
            let providerID = config.id
            providers[providerID] = provider
            logger.info("Registered remote provider: \(providerID, privacy: .public)")
        }
    }

    /// Load remote provider configs from user config file.
    public static func loadRemoteConfigs() throws -> [RemoteAPIProvider.Config] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vibecockpit/providers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RemoteAPIProvider.Config].self, from: data)
    }

    public func register(_ provider: some ModelProvider) {
        providers[provider.id] = provider
        logger.info("Registered provider: \(provider.id, privacy: .public)")
    }

    public func unregister(id: ProviderID) {
        providers.removeValue(forKey: id)
    }

    public func allProviders(with capabilities: ProviderCapabilities) -> [any ModelProvider] {
        providers.values.filter { $0.capabilities.contains(capabilities) }
    }

    public func preferredProvider(for task: InferenceTask) -> (any ModelProvider)? {
        let required: ProviderCapabilities
        switch task {
        case .textGeneration: required = .textGeneration
        case .embedding:      required = .embedding
        case .speculativeDraft: required = .speculativeDraft
        }
        return providers.values.first { $0.capabilities.contains(required) }
    }

    public var isEmpty: Bool { providers.isEmpty }

    public var providerCount: Int { providers.count }

    // MARK: - Local model discovery

    private func discoverLocalModels(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var bundleURLs: [URL] = []
        for item in enumerator {
            guard let url = item as? URL else { continue }
            let configURL = url.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configURL.path) else { continue }
            bundleURLs.append(url)
        }
        for url in bundleURLs {
            let name = url.lastPathComponent
            // LocalMLXProvider is only available when compiled with Xcode + Metal.
            logger.info("Found local model bundle at \(name, privacy: .public) — requires Xcode build with MLX enabled.")
        }
    }
}
