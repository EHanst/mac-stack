import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
import StackHTTP
#endif

/// "Share with other apps": runs the local API server and manages which apps may use it.
/// Off by default. The server only ever listens on 127.0.0.1 and every app needs its own token.
@MainActor
@Observable
public final class APISharingModel {

    public enum Status: Equatable, Sendable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    /// A token that has just been created. It is shown once and then gone.
    public struct NewToken: Equatable, Sendable, Identifiable {
        public let id = UUID()
        public let clientName: String
        public let token: String
    }

    public private(set) var status: Status = .off
    public private(set) var clients: [APIClient] = []
    public private(set) var newToken: NewToken?
    public private(set) var isEnabled: Bool
    /// Set when the saved list of apps couldn't be read; sharing stays off until it's fixed.
    public private(set) var loadError: String?

    public static let enabledKey = "apiSharingEnabled"
    public static let portKey = "apiSharingPort"

    public let port: Int
    private let defaults: UserDefaults
    private let inference: InferenceService
    private let registry: ClientRegistry?
    private var serverTask: Task<Void, Never>?
    private var generation = 0

    public init(inference: InferenceService, store: ClientStore = FileClientStore(url: FileClientStore.defaultURL()),
                defaults: UserDefaults = .standard, port: Int? = nil) {
        self.inference = inference
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        let saved = defaults.integer(forKey: Self.portKey)
        self.port = port ?? (saved > 0 ? saved : APIServerConfiguration.defaultPort)
        do {
            let registry = try ClientRegistry(store: store)
            self.registry = registry
            self.loadError = nil
        } catch {
            self.registry = nil
            self.loadError = "Couldn't read the list of apps (\(error.localizedDescription))."
        }
    }

    /// Address other apps use (OpenAI-style base URL).
    public var baseURL: String {
        let p: Int
        if case .running(let actual) = status { p = actual } else { p = port }
        return "http://127.0.0.1:\(p)/v1"
    }

    // MARK: Lifecycle

    /// Called at app launch: brings the server up if the user left it on.
    public func startIfEnabled() async {
        await reloadClients()
        if isEnabled { await startServer() }
    }

    public func setEnabled(_ on: Bool) async {
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { await startServer() } else { await stopServer() }
    }

    private func startServer() async {
        guard serverTask == nil else { return }
        guard let registry else { status = .failed(loadError ?? "Sharing isn't available."); return }
        status = .starting
        generation += 1
        let mine = generation
        let server = StackAPIServer(inference: inference, clients: registry, configuration: APIServerConfiguration(port: port))
        let port = self.port
        serverTask = Task { [weak self] in
            do {
                try await server.run(onListening: { actual in
                    await MainActor.run { if self?.generation == mine { self?.status = .running(port: actual) } }
                })
                await MainActor.run { if self?.generation == mine { self?.status = .off } }
            } catch {
                await MainActor.run {
                    guard let self, self.generation == mine else { return }
                    self.status = .failed(Self.describe(error, port: port))
                    self.serverTask = nil
                }
            }
        }
    }

    /// Stops the server and waits until the port is released.
    public func stopServer() async {
        generation += 1
        let task = serverTask
        serverTask = nil
        task?.cancel()
        await task?.value
        status = .off
    }

    static func describe(_ error: Error, port: Int) -> String {
        let text = String(describing: error)
        if text.lowercased().contains("address already in use") || text.contains("EADDRINUSE") {
            return "Port \(port) is already used by another program."
        }
        return "The server couldn't start: \(error.localizedDescription)"
    }

    // MARK: Apps

    public func reloadClients() async {
        clients = await registry?.all ?? []
    }

    /// Adds an app and shows its token once.
    @discardableResult
    public func createClient(name: String, scopes: Set<ClientScope> = ClientScope.defaultForNewClient) async -> Bool {
        guard let registry else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let (client, token) = try await registry.create(name: trimmed, scopes: scopes)
            newToken = NewToken(clientName: client.name, token: token)
            await reloadClients()
            return true
        } catch {
            loadError = "Couldn't save the new app: \(error.localizedDescription)"
            return false
        }
    }

    public func dismissNewToken() { newToken = nil }

    public func revoke(_ client: APIClient) async {
        try? await registry?.revoke(client.id)
        await reloadClients()
    }

    public func setScope(_ scope: ClientScope, enabled: Bool, for client: APIClient) async {
        var scopes = client.scopes
        if enabled { scopes.insert(scope) } else { scopes.remove(scope) }
        try? await registry?.setScopes(scopes, for: client.id)
        await reloadClients()
    }
}
