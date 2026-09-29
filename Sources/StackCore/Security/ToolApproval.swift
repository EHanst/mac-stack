import Foundation

/// Who is asking. `key` is stable across sessions ("client:<uuid>" for an app with a key,
/// "socket:<name>" for a local tool that connected over the Unix socket); `name` is what the
/// user sees.
public struct ClientIdentity: Sendable, Equatable, Hashable, Codable {
    public let key: String
    public let name: String
    public init(key: String, name: String) { self.key = key; self.name = name }
    public static let unknownLocalApp = ClientIdentity(key: "socket:unknown", name: "A local app")
}

/// One thing an outside app wants to do that the user should OK first.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let client: ClientIdentity
    public let toolName: String
    public let scope: ClientScope
    /// Plain-language description, e.g. "Write /path/File.swift (2.1 KB)".
    public let summary: String
    /// Outside content (web pages, other tools) already in the conversation. Non-empty means the
    /// request may have been steered by it, so "Always allow" is off the table.
    public let untrustedSources: [String]
    public init(client: ClientIdentity, toolName: String, scope: ClientScope, summary: String,
                untrustedSources: [String] = []) {
        self.client = client; self.toolName = toolName; self.scope = scope; self.summary = summary
        self.untrustedSources = untrustedSources
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case allowOnce
    /// Allow this kind of action for this app from now on (until the user forgets it in Settings).
    case allowAlways
    case deny
}

public protocol ToolApprover: Sendable {
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Reading is free; changing files and running commands need a yes.
public enum ApprovalPolicy {
    public static func needsApproval(_ scope: ClientScope) -> Bool {
        scope == .toolsWrite || scope == .toolsExec
    }
}

// MARK: Remembered approvals

public struct SavedApproval: Codable, Sendable, Equatable {
    public var name: String
    public var scopes: Set<ClientScope>
}

public protocol ApprovalStore: Sendable {
    func load() throws -> [String: SavedApproval]
    func save(_ approvals: [String: SavedApproval]) throws
}

/// JSON file, owner-only, atomic.
public struct FileApprovalStore: ApprovalStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/approvals.json")
    }
    public func load() throws -> [String: SavedApproval] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: SavedApproval].self, from: Data(contentsOf: url))
    }
    public func save(_ approvals: [String: SavedApproval]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(approvals)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".approvals-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// "Always allow" choices, per app and per kind of action.
public actor ApprovalMemory {
    private let store: any ApprovalStore
    private var saved: [String: SavedApproval]

    public init(store: any ApprovalStore = FileApprovalStore(url: FileApprovalStore.defaultURL())) {
        self.store = store
        self.saved = (try? store.load()) ?? [:]
    }

    public func isAllowed(_ client: ClientIdentity, _ scope: ClientScope) -> Bool {
        saved[client.key]?.scopes.contains(scope) ?? false
    }

    public func remember(_ client: ClientIdentity, _ scope: ClientScope) {
        var entry = saved[client.key] ?? SavedApproval(name: client.name, scopes: [])
        entry.name = client.name
        entry.scopes.insert(scope)
        saved[client.key] = entry
        try? store.save(saved)
    }

    public func forget(key: String) {
        guard saved.removeValue(forKey: key) != nil else { return }
        try? store.save(saved)
    }

    public func forget(key: String, scope: ClientScope) {
        guard var entry = saved[key] else { return }
        entry.scopes.remove(scope)
        if entry.scopes.isEmpty { saved.removeValue(forKey: key) } else { saved[key] = entry }
        try? store.save(saved)
    }

    /// For Settings: (key, entry), sorted by name.
    public var all: [(key: String, entry: SavedApproval)] {
        saved.map { ($0.key, $0.value) }.sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
    }
}

/// The single question every tool call answers: may this app do this right now?
public struct ToolGate: Sendable {
    public let memory: ApprovalMemory
    public let approver: (any ToolApprover)?

    /// Without an approver, anything that needs approval is refused.
    public init(memory: ApprovalMemory, approver: (any ToolApprover)?) {
        self.memory = memory
        self.approver = approver
    }

    public func allows(_ request: ApprovalRequest) async -> Bool {
        guard ApprovalPolicy.needsApproval(request.scope) else { return true }
        let tainted = !request.untrustedSources.isEmpty
        // A saved "always" was given for the user's own requests, not for whatever a web page asks.
        if !tainted, await memory.isAllowed(request.client, request.scope) { return true }
        guard let approver else { return false }
        switch await approver.decide(request) {
        case .allowOnce: return true
        case .allowAlways:
            if !tainted { await memory.remember(request.client, request.scope) }
            return true
        case .deny: return false
        }
    }
}
