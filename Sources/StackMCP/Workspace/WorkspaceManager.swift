import Foundation
import MCP
import os
#if SWIFT_PACKAGE
import StackCore
#endif

/// A project folder the user added. Each one gets its own tools, index and boundary, so one
/// project's files, search results and builds can't leak into another's.
public struct WorkspaceRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String       // stable, letters/digits/underscore
    public var name: String     // folder name, what the user sees
    public var path: String
    public init(id: String, name: String, path: String) { self.id = id; self.name = name; self.path = path }
    public var url: URL { URL(fileURLWithPath: path) }
}

public enum WorkspaceStatus: Sendable, Equatable {
    case opening
    case ready
    case failed(String)
}

public protocol WorkspaceStore: Sendable {
    func load() throws -> [WorkspaceRecord]
    func save(_ records: [WorkspaceRecord]) throws
}

public struct FileWorkspaceStore: WorkspaceStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/workspaces.json")
    }
    public func load() throws -> [WorkspaceRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([WorkspaceRecord].self, from: Data(contentsOf: url))
    }
    public func save(_ records: [WorkspaceRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}

public enum WorkspaceError: LocalizedError {
    case notAFolder(String)
    case tooBroad(String)
    case ambiguous(available: [String])
    case unknown(String, available: [String])
    public var errorDescription: String? {
        switch self {
        case .notAFolder(let p): "'\(p)' isn't a folder."
        case .tooBroad(let p): "'\(p)' is too broad to open as a project."
        case .ambiguous(let names): "More than one project is open. Say which with the 'workspace' argument: \(names.joined(separator: ", "))."
        case .unknown(let n, let names): "There is no open project called '\(n)'. Open projects: \(names.joined(separator: ", "))."
        }
    }
}

/// Holds every open project. `open` builds one project's tools (the app supplies it: index,
/// git, boundary, build runner); the manager names, persists, routes and lists them.
public actor WorkspaceManager {
    public typealias Opener = @Sendable (WorkspaceRecord) async throws -> [any AgentToolHandler]

    private let store: any WorkspaceStore
    private let open: Opener
    private(set) var records: [WorkspaceRecord]
    private var toolsByWorkspace: [String: [any AgentToolHandler]] = [:]
    private var statuses: [String: WorkspaceStatus] = [:]
    private var onChange: (@Sendable () -> Void)?
    private let log = Logger(subsystem: "com.vibecockpit", category: "WorkspaceManager")

    public init(store: any WorkspaceStore = FileWorkspaceStore(url: FileWorkspaceStore.defaultURL()), open: @escaping Opener) {
        self.store = store
        self.open = open
        self.records = (try? store.load()) ?? []
    }

    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) { onChange = handler }

    public var list: [(record: WorkspaceRecord, status: WorkspaceStatus)] {
        records.map { ($0, statuses[$0.id] ?? .opening) }
    }

    public func openAll() async { for r in records { await openOne(r) } }

    /// Adds a folder (or returns the existing record for the same path) and opens it.
    @discardableResult
    public func add(_ folder: URL) async throws -> WorkspaceRecord {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.notAFolder(path)
        }
        // Never the whole disk or the whole home folder: file tools would reach far too much.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard path != "/", path != home else { throw WorkspaceError.tooBroad(path) }
        if let existing = records.first(where: { $0.path == path }) { return existing }
        let name = URL(fileURLWithPath: path).lastPathComponent
        var id = ExternalMCPServer.makeID(from: name)
        let base = id; var n = 2
        while records.contains(where: { $0.id == id }) { id = "\(base)_\(n)"; n += 1 }
        let record = WorkspaceRecord(id: id, name: name, path: path)
        records.append(record)
        try store.save(records)
        await openOne(record)
        return record
    }

    public func remove(_ id: String) {
        records.removeAll { $0.id == id }
        toolsByWorkspace[id] = nil
        statuses[id] = nil
        try? store.save(records)
        onChange?()
    }

    private func openOne(_ record: WorkspaceRecord) async {
        statuses[record.id] = .opening; onChange?()
        do {
            toolsByWorkspace[record.id] = try await open(record)
            statuses[record.id] = .ready
        } catch {
            toolsByWorkspace[record.id] = nil
            statuses[record.id] = .failed(error.localizedDescription)
            log.error("workspace \(record.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
    }

    /// `list_workspaces` plus one routed tool per workspace tool name, across all ready projects.
    public func tools() -> [any AgentToolHandler] {
        let ready = records.filter { toolsByWorkspace[$0.id] != nil }
        guard !ready.isEmpty else { return [] }
        var order: [String] = []
        var grouped: [String: [WorkspaceRoutedTool.Entry]] = [:]
        for r in ready {
            for tool in toolsByWorkspace[r.id] ?? [] {
                let name = tool.toolDefinition.name
                if grouped[name] == nil { order.append(name) }
                grouped[name, default: []].append(.init(workspace: r, handler: tool))
            }
        }
        return [ListWorkspacesTool(workspaces: ready)] + order.compactMap { name in
            grouped[name].map { WorkspaceRoutedTool(entries: $0) }
        }
    }
}

// MARK: - Tools

public struct ListWorkspacesTool: AgentToolHandler {
    let workspaces: [WorkspaceRecord]
    public let toolDefinition = Tool(
        name: "list_workspaces",
        description: "List the projects open in Kokoro. Other tools take a 'workspace' argument naming one of these.",
        inputSchema: .object(["type": "object", "properties": .object([:])]))
    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        [.text(workspaces.map { "\($0.id): \($0.name) — \($0.path)" }.joined(separator: "\n"))]
    }
}

public enum RootMatch: Sendable, Equatable {
    case matched(String)          // workspace id
    case unmatched([String])      // the client's folders, none of which is an open project
}

/// One workspace tool (say `read_file`) across every open project. Adds a `workspace` argument,
/// strips it, and hands the call to that project's own tool. The argument is optional. Order of
/// choice: the project named; else the one the calling app's own folder is in (`match`); else the
/// only open project. With several open and no hint it is an error, so a write never lands in a
/// project by guess.
public struct WorkspaceRoutedTool: AgentToolHandler {
    public struct Entry: Sendable { let workspace: WorkspaceRecord; let handler: any AgentToolHandler }
    let entries: [Entry]
    let base: any AgentToolHandler

    init(entries: [Entry]) { self.entries = entries; self.base = entries[0].handler }

    /// Which open project a client's own folders point at. Nil when it offered none (then the
    /// old rule applies: the only open project, else the caller must say). A folder counts as
    /// inside a project when it is that folder or below it; the most specific project wins.
    public func match(rootPaths: [String]) -> RootMatch? {
        guard !rootPaths.isEmpty else { return nil }
        var best: (id: String, length: Int)?
        for raw in rootPaths {
            let root = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
            for entry in entries {
                let w = entry.workspace.path
                guard root == w || root.hasPrefix(w.hasSuffix("/") ? w : w + "/") else { continue }
                if best == nil || w.count > best!.length { best = (entry.workspace.id, w.count) }
            }
        }
        return best.map { .matched($0.id) } ?? .unmatched(rootPaths)
    }

    public var requiredScope: ClientScope { base.requiredScope }
    public var producesUntrustedContent: Bool { base.producesUntrustedContent }
    public var alwaysRequiresApproval: Bool { base.alwaysRequiresApproval }

    public var toolDefinition: Tool {
        let t = base.toolDefinition.withValidSchema
        guard case .object(var schema) = t.inputSchema, case .object(var props)? = schema["properties"] else { return t }
        let names = entries.map(\.workspace.name).joined(separator: ", ")
        props["workspace"] = .object(["type": "string", "description": .string(
            "Which open project (\(names)). Optional: defaults to the project the calling app is working in.")])
        schema["properties"] = .object(props)
        return Tool(name: t.name, title: t.title, description: t.description, inputSchema: .object(schema),
                    annotations: t.annotations, _meta: t._meta)
    }

    func resolve(_ arguments: [String: Value]) throws -> (Entry, [String: Value]) {
        var args = arguments
        let asked = args.removeValue(forKey: "workspace")
        guard case .string(let wanted)? = asked, !wanted.isEmpty else {
            if entries.count == 1 { return (entries[0], args) }
            throw WorkspaceError.ambiguous(available: entries.map(\.workspace.name))
        }
        let match = entries.first { $0.workspace.id == wanted }
            ?? entries.first { $0.workspace.name.caseInsensitiveCompare(wanted) == .orderedSame }
        guard let match else { throw WorkspaceError.unknown(wanted, available: entries.map(\.workspace.name)) }
        return (match, args)
    }

    public func approvalSummary(arguments: [String: Value]) -> String {
        guard let (entry, args) = try? resolve(arguments) else { return base.approvalSummary(arguments: arguments) + " (project not specified)" }
        return "[\(entry.workspace.name)] " + entry.handler.approvalSummary(arguments: args)
    }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let (entry, args) = try resolve(arguments)
        return try await entry.handler.execute(arguments: args)
    }
}
