import Foundation
import MCP
import os
#if SWIFT_PACKAGE
import StackCore
#endif

/// The MCP endpoint for local clients: a Unix socket that any number of tools (Claude Desktop,
/// Cursor, scripts via `kokoro-mcp`) can connect to at once, each with its own server.
/// The socket is owner-only, so a connection is the signed-in user and gets every permission.
public actor MCPService {

    private let host: MCPToolHost
    private var listener: UnixSocketListener?
    private var connections: [UUID: Task<Void, Never>] = [:]
    private var singleServerTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.vibecockpit", category: "MCPService")

    public private(set) var isRunning: Bool = false
    public private(set) var connectedClients: Int = 0

    public init(host: MCPToolHost) { self.host = host }

    public func start(socketPath: String) async throws {
        guard listener == nil else { return }
        let listener = UnixSocketListener(path: socketPath) { [weak self] transport in
            Task { await self?.serve(transport) }
        }
        try listener.start()
        self.listener = listener
        isRunning = true
        log.info("MCPService listening on \(socketPath, privacy: .public)")
    }

    /// One server per connection, until that client goes away.
    private func serve(_ transport: SocketConnectionTransport) async {
        let id = UUID()
        connectedClients += 1
        let box = ScopeBox(Set(ClientScope.allCases))
        let server = await host.makeServer(scopes: box)
        let log = self.log
        let task = Task {
            do {
                try await server.start(transport: transport, initializeHook: { info, _ in
                    box.identity = ClientIdentity(key: "socket:\(info.name)", name: info.title ?? info.name)
                })
            }
            catch { log.error("MCP connection ended: \(error.localizedDescription, privacy: .public)") }
            await server.waitUntilCompleted()
            await transport.disconnect()
        }
        connections[id] = task
        await task.value
        connections[id] = nil
        connectedClients -= 1
    }

    /// Serves one already-connected transport (used by tests and embedding hosts).
    func startWithTransport(_ transport: any Transport) async throws {
        let server = await host.makeServer(scopes: ScopeBox(Set(ClientScope.allCases)))
        isRunning = true
        let log = self.log
        singleServerTask = Task.detached(priority: .utility) {
            do { try await server.start(transport: transport) }
            catch { log.error("MCP server stopped: \(error.localizedDescription, privacy: .public)") }
        }
    }

    public func stop() async {
        listener?.stop()
        listener = nil
        singleServerTask?.cancel()
        singleServerTask = nil
        for task in connections.values { task.cancel() }
        connections.removeAll()
        connectedClients = 0
        isRunning = false
        log.info("MCPService stopped")
    }
}

// MARK: - search_code

struct SearchCodeTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "search_code",
        description: "Hybrid semantic + full-text search over indexed Swift declarations. Returns ranked results with file paths and code snippets.",
        inputSchema: .object([
            "query": .object(["type": "string", "description": "Natural language or keyword search query"]),
            "topK": .object(["type": "integer", "description": "Maximum results to return (default 10)"]),
        ])
    )

    let pipeline: IndexingPipeline

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let query) = arguments["query"] else {
            throw AgentToolError.missingArgument("query")
        }
        let topK: Int
        if case .int(let k) = arguments["topK"] { topK = k } else { topK = 10 }

        let results = try await pipeline.search(query: query, topK: topK)
        guard !results.isEmpty else {
            return [.text(text: "No results found.", annotations: nil, _meta: nil)]
        }
        let output = results.enumerated().map { idx, r in
            "\(idx + 1). [\(r.declarationKind)] \(r.filePath)\n\(r.content)"
        }.joined(separator: "\n\n---\n\n")
        return [.text(text: output, annotations: nil, _meta: nil)]
    }
}

// MARK: - index_workspace

struct RuntimeIndexWorkspaceTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "index_workspace",
        description: "Index or re-index all Swift files in a directory so they appear in search_code results.",
        inputSchema: .object([
            "path": .object(["type": "string", "description": "Directory to index. Must be within the workspace. Defaults to workspace root."]),
        ])
    )
    let runtime: ToolRuntime

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let url: URL
        if case .string(let path) = arguments["path"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = runtime.workspaceRoot
        }
        try await runtime.indexWorkspace(url)
        return [.text(text: "Indexed \(url.path)", annotations: nil, _meta: nil)]
    }
}

// MARK: - read_file

struct RuntimeFileReaderTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "read_file",
        description: "Read the contents of a file within the workspace.",
        inputSchema: .object([
            "path": .object(["type": "string", "description": "Absolute file path within the workspace"]),
            "startLine": .object(["type": "integer", "description": "First line (1-indexed, optional)"]),
            "endLine": .object(["type": "integer", "description": "Last line (1-indexed, optional)"]),
        ])
    )
    let runtime: ToolRuntime

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let path) = arguments["path"] else {
            throw AgentToolError.missingArgument("path")
        }
        let start = arguments["startLine"].flatMap { if case .int(let n) = $0 { return n } else { return nil } }
        let end   = arguments["endLine"].flatMap   { if case .int(let n) = $0 { return n } else { return nil } }
        let content = try await runtime.readFile(path: URL(fileURLWithPath: path), startLine: start, endLine: end)
        return [.text(text: content, annotations: nil, _meta: nil)]
    }
}

// MARK: - write_file

struct RuntimeFileWriterTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "write_file",
        description: "Write or overwrite a file within the workspace.",
        inputSchema: .object([
            "path": .object(["type": "string", "description": "Absolute file path within the workspace"]),
            "content": .object(["type": "string", "description": "File content to write"]),
            "createDirectories": .object(["type": "boolean", "description": "Create parent directories if missing"]),
        ])
    )
    let runtime: ToolRuntime
    var requiredScope: ClientScope { .toolsWrite }
    func approvalSummary(arguments: [String: Value]) -> String {
        guard case .string(let path) = arguments["path"] else { return "Write a file" }
        var size = ""
        if case .string(let content) = arguments["content"] {
            size = " (" + ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file) + ")"
        }
        return "Write \(path)\(size)"
    }

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let path) = arguments["path"],
              case .string(let content) = arguments["content"] else {
            throw AgentToolError.missingArgument("path or content")
        }
        let mkdir: Bool
        if case .bool(let b) = arguments["createDirectories"] { mkdir = b } else { mkdir = false }
        try await runtime.writeFile(path: URL(fileURLWithPath: path), content: content, createDirectories: mkdir)
        return [.text(text: "Written: \(path)", annotations: nil, _meta: nil)]
    }
}

// MARK: - run_build

struct RuntimeRunBuildTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "run_build",
        description: "Run a build command in the project workspace. Working directory must be within the workspace.",
        inputSchema: .object([
            "command": .object(["type": "string", "description": "Shell command to execute"]),
            "workingDirectory": .object(["type": "string", "description": "Working directory (must be within workspace)"]),
            "timeoutSeconds": .object(["type": "integer", "description": "Timeout in seconds (default 120)"]),
        ])
    )
    let runtime: ToolRuntime
    var requiredScope: ClientScope { .toolsExec }
    func approvalSummary(arguments: [String: Value]) -> String {
        guard case .string(let command) = arguments["command"] else { return "Run a command" }
        return "Run: \(command)"
    }

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let command) = arguments["command"],
              case .string(let wd) = arguments["workingDirectory"] else {
            throw AgentToolError.missingArgument("command or workingDirectory")
        }
        let timeout: Duration = {
            if case .int(let s) = arguments["timeoutSeconds"] { return .seconds(s) }
            return .seconds(120)
        }()
        let result = try await runtime.runBuild(command: command,
                                                 workingDirectory: URL(fileURLWithPath: wd),
                                                 timeout: timeout)
        return [.text(text: "exit: \(result.exitCode)\n\(result.stdout)\(result.stderr)", annotations: nil, _meta: nil)]
    }
}

// MARK: - snapshot_create

struct SnapshotCreateTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "snapshot_create",
        description: "Create a git snapshot of the current workspace state. Returns the snapshot OID for use with snapshot_diff.",
        inputSchema: .object([
            "message": .object(["type": "string", "description": "Snapshot description"]),
        ])
    )
    let manager: GitSnapshotManager
    var requiredScope: ClientScope { .toolsWrite }
    func approvalSummary(arguments: [String: Value]) -> String { "Save a snapshot of your project" }

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let message: String
        if case .string(let m) = arguments["message"] { message = m }
        else { message = "Kokoro snapshot" }

        let ref = try await manager.createSnapshot(message: message)
        return [.text(text: "Snapshot \(ref.oid) — \(ref.message)", annotations: nil, _meta: nil)]
    }
}

// MARK: - snapshot_diff

struct SnapshotDiffTool: AgentToolHandler {
    let toolDefinition = Tool(
        name: "snapshot_diff",
        description: "List files changed since a previous snapshot. Pass the OID returned by snapshot_create.",
        inputSchema: .object([
            "oid": .object(["type": "string", "description": "Snapshot OID from snapshot_create"]),
        ])
    )
    let manager: GitSnapshotManager

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let oid) = arguments["oid"] else {
            throw AgentToolError.missingArgument("oid")
        }
        let ref = SnapshotRef(id: UUID(), oid: oid, message: "", createdAt: Date(), branchName: "")
        let diff = try await manager.diffAgainstSnapshot(ref)
        if diff.isEmpty {
            return [.text(text: "No changes since snapshot \(oid).", annotations: nil, _meta: nil)]
        }
        let paths = diff.hunks.map { $0.filePath }.joined(separator: "\n")
        return [.text(text: "Changed files since \(oid):\n\(paths)", annotations: nil, _meta: nil)]
    }
}
