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
        return providers.values
            .filter { $0.capabilities.contains(required) }
            .sorted { $0.id < $1.id }
            .first
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
            let hasSafetensors = FileManager.default.fileExists(
                atPath: url.appendingPathComponent("model.safetensors").path) ||
                FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("model.safetensors.index.json").path)
            guard FileManager.default.fileExists(atPath: configURL.path) && hasSafetensors else {
                continue
            }
            bundleURLs.append(url)
        }

        for url in bundleURLs {
            let name = url.lastPathComponent
            guard isMLXCompatibleModel(at: url) else {
                logger.info("Skipping \(name, privacy: .public): unsupported model type")
                continue
            }
            let providerID = "local:\(name)"
            if providers[providerID] == nil {
                providers[providerID] = LocalMLXProvider(id: providerID, modelDirectory: url)
                logger.info("Registered local model: \(name, privacy: .public)")
            }
        }
    }

    private func isMLXCompatibleModel(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }  // no config → assume compatible
        let modelType = dict["model_type"] as? String ?? ""
        // Supported: Prism Hadamard Qwen3.5, standard Qwen3/Qwen2, and unknowns
        let unsupported = ["llama", "mistral", "gemma", "phi"]
        return !unsupported.contains(modelType.lowercased())
    }
}
