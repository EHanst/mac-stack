import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore
@testable import StackHTTP

private final class MemoryStore: ClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [APIClient] = []
    func load() throws -> [APIClient] { lock.withLock { clients } }
    func save(_ c: [APIClient]) throws { lock.withLock { clients = c } }
}

private func freshDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: "api-sharing-\(UUID().uuidString)")!
    return d
}

@MainActor
private func makeModel(defaults: UserDefaults = freshDefaults(), store: ClientStore = MemoryStore(), port: Int? = 0) -> APISharingModel {
    APISharingModel(inference: InferenceService(registry: ModelRegistry()), store: store, defaults: defaults, port: port)
}

@MainActor
private func waitForPort(_ model: APISharingModel) async throws -> Int {
    for _ in 0..<100 {
        if case .running(let p) = model.status { return p }
        if case .failed = model.status { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("server did not start: \(model.status)")
    return 0
}

private func status(_ path: String, port: Int, token: String? = nil) async -> Int? {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
}

@Suite("APISharingModel")
@MainActor
struct APISharingModelTests {

    @Test("sharing is off by default and nothing listens")
    func offByDefault() async {
        let model = makeModel()
        await model.startIfEnabled()
        #expect(model.isEnabled == false)
        #expect(model.status == .off)
    }

    @Test("turning it on serves the API on loopback; turning it off releases the port")
    func onAndOff() async throws {
        let model = makeModel()
        await model.setEnabled(true)
        let port = try await waitForPort(model)
        #expect(await status("/healthz", port: port) == 200)
        #expect(model.baseURL == "http://127.0.0.1:\(port)/v1")

        await model.setEnabled(false)
        #expect(model.status == .off)
        #expect(await status("/healthz", port: port) == nil)
    }

    @Test("the switch is remembered and the server comes back at launch")
    func persisted() async throws {
        let defaults = freshDefaults(), store = MemoryStore()
        let first = makeModel(defaults: defaults, store: store)
        await first.setEnabled(true)
        _ = try await waitForPort(first)
        await first.stopServer()

        let second = makeModel(defaults: defaults, store: store)
        #expect(second.isEnabled)
        await second.startIfEnabled()
        _ = try await waitForPort(second)
        await second.stopServer()
    }

    @Test("a new app gets a token that works once, and revoking it stops it")
    func clientLifecycle() async throws {
        let model = makeModel()
        await model.setEnabled(true)
        let port = try await waitForPort(model)

        #expect(await model.createClient(name: "  Cursor "))
        let token = try #require(model.newToken)
        #expect(token.clientName == "Cursor")
        #expect(token.token.hasPrefix("vc_"))
        #expect(model.clients.map(\.name) == ["Cursor"])
        #expect(await status("/v1/models", port: port, token: token.token) == 200)

        model.dismissNewToken()
        #expect(model.newToken == nil)

        await model.revoke(model.clients[0])
        #expect(model.clients[0].isActive == false)
        #expect(await status("/v1/models", port: port, token: token.token) == 401)
        await model.stopServer()
    }

    @Test("empty names are rejected")
    func emptyName() async {
        let model = makeModel()
        #expect(await model.createClient(name: "   ") == false)
        #expect(model.clients.isEmpty)
        #expect(model.newToken == nil)
    }

    @Test("changing an app's permissions takes effect immediately")
    func scopes() async throws {
        let model = makeModel()
        await model.setEnabled(true)
        let port = try await waitForPort(model)
        await model.createClient(name: "App")
        let token = try #require(model.newToken).token

        await model.setScope(.models, enabled: false, for: model.clients[0])
        #expect(await status("/v1/models", port: port, token: token) == 403)
        await model.setScope(.models, enabled: true, for: model.clients[0])
        #expect(await status("/v1/models", port: port, token: token) == 200)
        await model.stopServer()
    }

    @Test("a port that's already taken is reported in plain words")
    func portInUse() async throws {
        let a = makeModel()
        await a.setEnabled(true)
        let port = try await waitForPort(a)

        let b = makeModel(port: port)
        await b.setEnabled(true)
        for _ in 0..<100 { if case .failed = b.status { break }; try await Task.sleep(for: .milliseconds(50)) }
        guard case .failed(let message) = b.status else { Issue.record("expected failure, got \(b.status)"); return }
        #expect(message.contains("already used"), "\(message)")
        await a.stopServer()
        await b.stopServer()
    }
}
