import Foundation
import Testing
@testable import StackCore

@Suite("CredentialStore")
struct CredentialStoreTests {

    @Test("token throws notFound when credential is absent")
    func missingTokenThrows() async {
        let uniqueService = "com.vibecockpit.test.\(UUID().uuidString)"
        let store = CredentialStore(service: uniqueService)

        await #expect(throws: CredentialStore.CredentialError.self) {
            _ = try await store.token(for: "nonexistent-provider")
        }
        let has = await store.hasToken(for: "nonexistent-provider")
        #expect(!has)
    }

    @Test("stores, retrieves, updates, and deletes tokens in keychain")
    func keychainStoreRetrieveDelete() async throws {
        let uniqueService = "com.vibecockpit.test.\(UUID().uuidString)"
        let store = CredentialStore(service: uniqueService)
        let provider = "test-provider-\(UUID().uuidString)"

        defer {
            Task {
                try? await store.delete(for: provider)
            }
        }

        // Initially absent
        #expect(await !store.hasToken(for: provider))

        // Store new token (SecItemAdd path)
        try await store.store(token: "sk-initial-12345", for: provider)
        #expect(await store.hasToken(for: provider))
        let fetched = try await store.token(for: provider)
        #expect(fetched == "sk-initial-12345")

        // Overwrite token (SecItemUpdate path)
        try await store.store(token: "sk-updated-67890", for: provider)
        let updated = try await store.token(for: provider)
        #expect(updated == "sk-updated-67890")

        // Delete token
        try await store.delete(for: provider)
        #expect(await !store.hasToken(for: provider))

        // Deleting already deleted item succeeds without error
        try await store.delete(for: provider)
    }

    @Test("environment variables provide fallback when keychain is empty")
    func envVarFallback() async throws {
        let uniqueService = "com.vibecockpit.test.\(UUID().uuidString)"
        let store = CredentialStore(service: uniqueService)
        let provider = "env-provider"
        let envKey = "PATH" // Standard env variable guaranteed to exist

        #expect(await !store.hasToken(for: provider))

        await store.registerEnvVarKey(envKey, for: provider)
        #expect(await store.hasToken(for: provider))

        let token = try await store.token(for: provider)
        #expect(!token.isEmpty)
        #expect(token == ProcessInfo.processInfo.environment[envKey])
    }

    @Test("keychain token takes precedence over environment variable")
    func keychainPrecedenceOverEnv() async throws {
        let uniqueService = "com.vibecockpit.test.\(UUID().uuidString)"
        let store = CredentialStore(service: uniqueService)
        let provider = "precedence-provider-\(UUID().uuidString)"
        let envKey = "PATH"

        defer {
            Task {
                try? await store.delete(for: provider)
            }
        }

        await store.registerEnvVarKey(envKey, for: provider)
        try await store.store(token: "keychain-token", for: provider)

        let token = try await store.token(for: provider)
        #expect(token == "keychain-token")
    }

    @Test("error descriptions format clearly without leaking secrets")
    func errorDescriptions() {
        let notFound = CredentialStore.CredentialError.notFound("anthropic")
        #expect(notFound.errorDescription?.contains("anthropic") == true)

        let keychainFail = CredentialStore.CredentialError.keychainFailure(-25300)
        #expect(keychainFail.errorDescription == "Keychain operation failed.")

        let invalidFile = CredentialStore.CredentialError.credentialsFileInvalid("/path/to/creds.json")
        #expect(invalidFile.errorDescription?.contains("/path/to/creds.json") == true)
    }
}
