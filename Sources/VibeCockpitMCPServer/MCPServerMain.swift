import Foundation
import MCP
import VibeCockpitCore

@main
struct MCPServerMain {
    static func main() async throws {
        let workspaceURL = parseWorkspaceURL()

        let dbDir = workspaceURL.appendingPathComponent(".vibecockpit")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let store = VectorStore(dbURL: dbDir.appendingPathComponent("index.sqlite"))
        let registry = ModelRegistry()
        let pipeline = IndexingPipeline(store: store, registry: registry)
        try await pipeline.open()

        let gitManager = GitSnapshotManager(workspaceURL: workspaceURL)
        try? await gitManager.open()

        let buildRunner = XPCBuildRunner()

        let ctx = WorkspaceContext(
            root: workspaceURL,
            workspaceID: WorkspaceID(rawValue: workspaceURL.lastPathComponent),
            policy: .default
        )
        let boundary = WorkspaceBoundary(context: ctx)
        let runtime = ToolRuntime(boundary: boundary, buildRunner: buildRunner,
                                  gitManager: gitManager, pipeline: pipeline)

        let tools: [any AgentToolHandler] = [
            SearchCodeTool(pipeline: pipeline),
            RuntimeIndexWorkspaceTool(runtime: runtime),
            RuntimeFileReaderTool(runtime: runtime),
            RuntimeFileWriterTool(runtime: runtime),
            RuntimeRunBuildTool(runtime: runtime),
            SnapshotCreateTool(manager: gitManager),
            SnapshotDiffTool(manager: gitManager),
        ]

        let server = Server(
            name: "vibecockpit",
            version: "1.0.0",
            title: "VibeCockpit",
            instructions: """
                AI coding assistant with code search, indexing, git snapshots, and build execution \
                for macOS Swift projects. Workspace: \(workspaceURL.path)
                """,
            capabilities: Server.Capabilities(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools.map { $0.toolDefinition })
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard let handler = tools.first(where: { $0.toolDefinition.name == params.name }) else {
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
            let opID = OperationID()
            let task = Task<[Tool.Content], Error> {
                try await handler.execute(arguments: params.arguments ?? [:])
            }
            let voidTask: Task<Void, Error> = Task { _ = try await task.value }
            await runtime.trackTask(opID, task: voidTask)
            do {
                let content = try await task.value
                await runtime.removeTask(opID)
                return CallTool.Result(content: content)
            } catch is CancellationError {
                return CallTool.Result(
                    content: [.text(text: "Operation cancelled", annotations: nil, _meta: nil)],
                    isError: true
                )
            } catch {
                await runtime.removeTask(opID)
                return CallTool.Result(
                    content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private static func parseWorkspaceURL() -> URL {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--workspace"), idx + 1 < args.count {
            return URL(fileURLWithPath: args[idx + 1])
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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

// MARK: - index_workspace (runtime-backed)

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

// MARK: - read_file (runtime-backed)

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

// MARK: - write_file (runtime-backed)

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

// MARK: - run_build (runtime-backed)

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

    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let message: String
        if case .string(let m) = arguments["message"] { message = m }
        else { message = "VibeCockpit snapshot" }

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
