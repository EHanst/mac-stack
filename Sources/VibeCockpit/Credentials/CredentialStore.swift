import Foundation
import Security
import os

/// Resolves API tokens via: Keychain → environment variable → credentials file.
/// Tokens are never logged, serialized to disk unencrypted, or included in Error messages.
public actor CredentialStore {

    public enum CredentialError: LocalizedError, Sendable {
        case notFound(ProviderID)
        case keychainFailure(OSStatus)
        case credentialsFileInvalid(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id): "No credential found for provider '\(id)'."
            case .keychainFailure: "Keychain operation failed."
            case .credentialsFileInvalid(let path): "Credentials file at '\(path)' is not valid JSON."
            }
        }
    }

    private let service = "com.vibecockpit.credentials"
    private let logger = Logger(subsystem: "com.vibecockpit", category: "CredentialStore")

    // Provider id → env var key, populated from providers config
    private var envVarKeys: [ProviderID: String] = [:]

    public init() {}

    public func registerEnvVarKey(_ key: String, for providerID: ProviderID) {
        envVarKeys[providerID] = key
    }

    public func token(for providerID: ProviderID) async throws -> String {
        // 1. Keychain
        if let token = keychainToken(for: providerID) {
            return token
        }
        // 2. Environment variable
        if let key = envVarKeys[providerID], let value = ProcessInfo.processInfo.environment[key] {
            logger.info("Token for provider \(providerID, privacy: .public) loaded from environment.")
            return value
        }
        // 3. Credentials file (plaintext fallback — warned in UI)
        if let token = try credentialsFileToken(for: providerID) {
            logger.warning("Token for provider \(providerID, privacy: .public) loaded from plaintext credentials file. Consider using Keychain storage.")
            return token
        }
        throw CredentialError.notFound(providerID)
    }

    public func store(token: String, for providerID: ProviderID) async throws {
        let account = providerID
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CredentialError.keychainFailure(status)
        }
        logger.info("Token for provider \(providerID, privacy: .public) stored to Keychain.")
    }

    public func delete(for providerID: ProviderID) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychainFailure(status)
        }
    }

    public func hasToken(for providerID: ProviderID) async -> Bool {
        if keychainToken(for: providerID) != nil { return true }
        if let key = envVarKeys[providerID], ProcessInfo.processInfo.environment[key] != nil { return true }
        return (try? credentialsFileToken(for: providerID)) != nil
    }

    // MARK: - Private helpers

    private func keychainToken(for providerID: ProviderID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func credentialsFileToken(for providerID: ProviderID) throws -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vibecockpit/credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CredentialError.credentialsFileInvalid(url.path)
        }
        return dict[providerID]
    }
}
