import Crypto
import Foundation

/// What an outside app is allowed to do with the stack.
public enum ClientScope: String, Codable, CaseIterable, Sendable, Hashable {
    case models          // list models
    case chat            // generate text
    case embeddings      // compute embeddings
    case toolsRead       // tools that only read (search code, read files)
    case toolsWrite      // tools that change files
    case toolsExec       // tools that run commands
    case prompts         // read the saved prompts
    case briefs          // read the compiled briefs

    public var title: String {
        switch self {
        case .models:      "See which models are available"
        case .chat:        "Chat with the model"
        case .embeddings:  "Compute embeddings"
        case .toolsRead:   "Read your files and search code"
        case .toolsWrite:  "Change files"
        case .toolsExec:   "Run build commands"
        case .prompts:     "Read your saved prompts"
        case .briefs:      "Read your briefs"
        }
    }

    /// A new client can talk to the model but cannot touch files unless the user adds those.
    public static let defaultForNewClient: Set<ClientScope> = [.models, .chat, .embeddings]
}

/// One outside app that has been given access. The token itself is never stored — only its hash.
public struct APIClient: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var scopes: Set<ClientScope>
    /// SHA-256 of the token, hex.
    let tokenHash: String
    /// First characters of the token, for recognising it in a list ("vc_ab12cd34…").
    public let tokenPrefix: String
    public let createdAt: Date
    public var lastUsedAt: Date?
    public var revokedAt: Date?

    public var isActive: Bool { revokedAt == nil }
    public func allows(_ scope: ClientScope) -> Bool { isActive && scopes.contains(scope) }
}

/// Where clients are kept between launches.
public protocol ClientStore: Sendable {
    func load() throws -> [APIClient]
    func save(_ clients: [APIClient]) throws
}

/// JSON file with owner-only permissions, written atomically.
public struct FileClientStore: ClientStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/clients.json")
    }

    public func load() throws -> [APIClient] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([APIClient].self, from: Data(contentsOf: url))
    }

    public func save(_ clients: [APIClient]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clients)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write to a private temp file first so the token hashes are never briefly world-readable.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".clients-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Issues and checks access tokens for outside apps (the HTTP API and MCP over HTTP/sockets).
///
/// Tokens look like `vc_<43 url-safe characters>` (256 random bits). They are shown to the user
/// once, when created; afterwards only a SHA-256 hash exists on disk, so a copy of the file can't
/// be replayed against the server.
public actor ClientRegistry {

    private let store: any ClientStore
    private var clients: [APIClient]
    private var byHash: [String: Int] = [:]
    private var dirtyLastUsed = false
    private var lastFlush = Date.distantPast
    private let now: @Sendable () -> Date

    /// How often "last used" timestamps are written to disk while requests keep arriving.
    static let flushInterval: TimeInterval = 60

    public init(store: any ClientStore = FileClientStore(url: FileClientStore.defaultURL()),
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.store = store
        self.now = now
        let loaded = try store.load()
        self.clients = loaded
        self.byHash = Self.index(loaded)
    }

    // MARK: Tokens

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "vc_" + b64
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Management

    public var all: [APIClient] { clients.sorted { $0.createdAt < $1.createdAt } }

    /// Create a client. The returned token is the only time it is available in the clear.
    @discardableResult
    public func create(name: String, scopes: Set<ClientScope> = ClientScope.defaultForNewClient) throws
        -> (client: APIClient, token: String)
    {
        let token = Self.generateToken()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = APIClient(
            id: UUID(), name: trimmed.isEmpty ? "Untitled app" : trimmed, scopes: scopes,
            tokenHash: Self.hash(token), tokenPrefix: String(token.prefix(11)),
            createdAt: now(), lastUsedAt: nil, revokedAt: nil)
        clients.append(client)
        reindex()
        try store.save(clients)
        return (client, token)
    }

    public func revoke(_ id: UUID) throws {
        guard let i = clients.firstIndex(where: { $0.id == id }), clients[i].revokedAt == nil else { return }
        clients[i].revokedAt = now()
        try store.save(clients)
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { clients[i].name = trimmed }
        try store.save(clients)
    }

    public func setScopes(_ scopes: Set<ClientScope>, for id: UUID) throws {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[i].scopes = scopes
        try store.save(clients)
    }

    // MARK: Checking

    /// The active client that owns `token`, or nil. Records the time of use.
    public func authenticate(token: String) -> APIClient? {
        guard token.hasPrefix("vc_"), let i = byHash[Self.hash(token)], clients[i].isActive else { return nil }
        clients[i].lastUsedAt = now()
        dirtyLastUsed = true
        flushLastUsedIfDue()
        return clients[i]
    }

    /// Write pending "last used" times (also called on shutdown).
    public func flush() throws {
        guard dirtyLastUsed else { return }
        try store.save(clients)
        dirtyLastUsed = false
        lastFlush = now()
    }

    private func flushLastUsedIfDue() {
        guard dirtyLastUsed, now().timeIntervalSince(lastFlush) >= Self.flushInterval else { return }
        try? flush()
    }

    private func reindex() { byHash = Self.index(clients) }

    private static func index(_ clients: [APIClient]) -> [String: Int] {
        Dictionary(clients.enumerated().map { ($0.element.tokenHash, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }
}
