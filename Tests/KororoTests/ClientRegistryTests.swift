import Testing
import Foundation
@testable import KororoCore
@testable import StackCore
@testable import StackMCP

private final class MemoryStore: ClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [APIClient] = []
    var saves = 0
    func load() throws -> [APIClient] { lock.withLock { clients } }
    func save(_ c: [APIClient]) throws { lock.withLock { clients = c; saves += 1 } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    var now: Date { lock.withLock { t } }
}

@Suite("ClientRegistry")
struct ClientRegistryTests {

    @Test("a created client gets a vc_ token that authenticates as that client")
    func createAndAuthenticate() async throws {
        let r = try ClientRegistry(store: MemoryStore())
        let (client, token) = try await r.create(name: "Cursor")
        #expect(token.hasPrefix("vc_") && token.count == 46)          // vc_ + 43 base64url chars (256 bits)
        #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
        let found = await r.authenticate(token: token)
        #expect(found?.id == client.id && found?.name == "Cursor")
    }

    @Test("wrong, malformed and empty tokens never authenticate")
    func rejects() async throws {
        let r = try ClientRegistry(store: MemoryStore())
        let (_, token) = try await r.create(name: "A")
        #expect(await r.authenticate(token: token + "x") == nil)
        #expect(await r.authenticate(token: String(token.dropLast())) == nil)
        #expect(await r.authenticate(token: "") == nil)
        #expect(await r.authenticate(token: "Bearer " + token) == nil)
        #expect(await r.authenticate(token: String(token.dropFirst(3))) == nil)   // without the vc_ prefix
    }

    @Test("every token is unique and only its hash is kept")
    func uniqueAndHashed() async throws {
        let store = MemoryStore()
        let r = try ClientRegistry(store: store)
        let (a, ta) = try await r.create(name: "A")
        let (b, tb) = try await r.create(name: "B")
        #expect(ta != tb && a.tokenHash != b.tokenHash)
        let stored = try store.load()
        #expect(stored.allSatisfy { !$0.tokenHash.contains("vc_") && $0.tokenHash.count == 64 })
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
        #expect(!json.contains(ta) && !json.contains(tb))              // plaintext token is nowhere in what is saved
    }

    @Test("revoking stops the token immediately and is remembered")
    func revoke() async throws {
        let store = MemoryStore()
        let r = try ClientRegistry(store: store)
        let (client, token) = try await r.create(name: "A")
        try await r.revoke(client.id)
        #expect(await r.authenticate(token: token) == nil)
        let reloaded = try ClientRegistry(store: store)
        #expect(await reloaded.authenticate(token: token) == nil)
        #expect(await reloaded.all.first?.revokedAt != nil)
    }

    @Test("clients and their tokens survive a restart")
    func persistence() async throws {
        let store = MemoryStore()
        let (client, token) = try await ClientRegistry(store: store).create(name: "Claude Desktop", scopes: [.chat])
        let again = try ClientRegistry(store: store)
        let found = await again.authenticate(token: token)
        #expect(found?.id == client.id && found?.scopes == [.chat])
    }

    @Test("new clients can chat but cannot touch files; scopes are enforced per client")
    func scopes() async throws {
        let r = try ClientRegistry(store: MemoryStore())
        let (client, token) = try await r.create(name: "A")
        let c = try #require(await r.authenticate(token: token))
        #expect(c.allows(.chat) && c.allows(.models) && c.allows(.embeddings))
        #expect(!c.allows(.toolsRead) && !c.allows(.toolsWrite) && !c.allows(.toolsExec))
        try await r.setScopes([.chat, .toolsRead], for: client.id)
        let updated = try #require(await r.authenticate(token: token))
        #expect(updated.allows(.toolsRead) && !updated.allows(.embeddings))
    }

    @Test("a revoked client allows nothing")
    func revokedAllowsNothing() async throws {
        let r = try ClientRegistry(store: MemoryStore())
        let (client, _) = try await r.create(name: "A", scopes: Set(ClientScope.allCases))
        try await r.revoke(client.id)
        let revoked = try #require(await r.all.first)
        #expect(ClientScope.allCases.allSatisfy { !revoked.allows($0) })
    }

    @Test("blank names get a placeholder; rename ignores blanks")
    func names() async throws {
        let r = try ClientRegistry(store: MemoryStore())
        let (client, _) = try await r.create(name: "   ")
        #expect(client.name == "Untitled app")
        try await r.rename(client.id, to: "  ")
        #expect(await r.all.first?.name == "Untitled app")
        try await r.rename(client.id, to: " Zed ")
        #expect(await r.all.first?.name == "Zed")
    }

    @Test("'last used' is recorded, but written to disk at most once a minute")
    func lastUsedDebounce() async throws {
        let store = MemoryStore(), clock = Clock()
        let r = try ClientRegistry(store: store, now: { clock.now })
        let (_, token) = try await r.create(name: "A")
        let base = store.saves
        clock.advance(61)
        _ = await r.authenticate(token: token)                        // due: flushes
        #expect(store.saves == base + 1)
        for _ in 0..<50 { clock.advance(0.1); _ = await r.authenticate(token: token) }
        #expect(store.saves == base + 1)                              // a burst of requests doesn't hammer the disk
        clock.advance(61)
        _ = await r.authenticate(token: token)
        #expect(store.saves == base + 2)
        #expect(await r.all.first?.lastUsedAt != nil)
    }
}

@Suite("FileClientStore")
struct FileClientStoreTests {

    @Test("the file is owner-only and contains no plaintext token")
    func fileIsPrivate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clients_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clients.json")
        let r = try ClientRegistry(store: FileClientStore(url: url))
        let (_, token) = try await r.create(name: "A")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains(token))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("a fresh registry over a file written earlier finds the same client")
    func reload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clients_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clients.json")
        let (client, token) = try await ClientRegistry(store: FileClientStore(url: url)).create(name: "Zed")
        let again = try ClientRegistry(store: FileClientStore(url: url))
        #expect(await again.authenticate(token: token)?.id == client.id)
    }
}
