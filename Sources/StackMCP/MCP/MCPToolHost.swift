import Foundation
import MCP
import os
#if SWIFT_PACKAGE
import StackCore
#endif

/// What one connection is currently allowed to do. HTTP sessions update it on every request, so
/// removing a permission in Settings takes effect on the next call.
public final class ScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<ClientScope>
    public init(_ scopes: Set<ClientScope>) { value = scopes }
    public var scopes: Set<ClientScope> {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The tools VibeCockpit offers over MCP, and a factory for one `Server` per connected client.
/// Model tools (`list_models`, `chat`, `embed`) are always there; workspace tools appear once a
/// project is attached. Each server only shows and runs the tools its client's permissions allow.
public actor MCPToolHost {

    private let inference: InferenceService?
    private var workspaceTools: [any AgentToolHandler] = []
    private var runtime: ToolRuntime?
    private let log = Logger(subsystem: "com.vibecockpit", category: "MCPToolHost")

    public init(inference: InferenceService? = nil) { self.inference = inference }

    public var hasWorkspace: Bool { runtime != nil }

    /// Adds the code-search, file, build and snapshot tools. Applies to connections made afterwards.
    public func attachWorkspace(runtime: ToolRuntime, pipeline: IndexingPipeline, gitManager: GitSnapshotManager) {
        self.runtime = runtime
        workspaceTools = [
            SearchCodeTool(pipeline: pipeline),
            RuntimeIndexWorkspaceTool(runtime: runtime),
            RuntimeFileReaderTool(runtime: runtime),
            RuntimeFileWriterTool(runtime: runtime),
            RuntimeRunBuildTool(runtime: runtime),
            SnapshotCreateTool(manager: gitManager),
            SnapshotDiffTool(manager: gitManager),
        ]
    }

    public func allTools() -> [any AgentToolHandler] {
        var tools: [any AgentToolHandler] = []
        if let inference {
            tools += [ListModelsTool(inference: inference), ChatTool(inference: inference), EmbedTool(inference: inference)]
        }
        return tools + workspaceTools
    }

    /// A server for one client. `scopes` is consulted on every list and call.
    public func makeServer(scopes: ScopeBox) async -> Server {
        let tools = allTools()
        let runtime = self.runtime
        let log = self.log
        let server = Server(
            name: "vibecockpit",
            version: "1.0.0",
            title: "VibeCockpit",
            instructions: "The AI model running in VibeCockpit on this Mac (chat, embeddings, model list), plus code search, files, builds and snapshots when a project is open.",
            capabilities: Server.Capabilities(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            let allowed = scopes.scopes
            return ListTools.Result(tools: tools.filter { allowed.contains($0.requiredScope) }.map { $0.toolDefinition })
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard let handler = tools.first(where: { $0.toolDefinition.name == params.name }) else {
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
            guard scopes.scopes.contains(handler.requiredScope) else {
                return CallTool.Result(
                    content: [.text(text: "This app isn't allowed to \(handler.requiredScope.title.lowercased()). Change its permissions in VibeCockpit.", annotations: nil, _meta: nil)],
                    isError: true)
            }
            let opID = OperationID()
            let task = Task<[Tool.Content], Error> { try await handler.execute(arguments: params.arguments ?? [:]) }
            if let runtime {
                await runtime.trackTask(opID, task: Task<Void, Error> { _ = try await task.value })
            }
            func finish() async { if let runtime { await runtime.removeTask(opID) } }
            do {
                let content = try await task.value
                await finish()
                return CallTool.Result(content: content)
            } catch is CancellationError {
                await finish()
                return CallTool.Result(content: [.text(text: "Operation cancelled", annotations: nil, _meta: nil)], isError: true)
            } catch {
                await finish()
                log.error("tool \(params.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return CallTool.Result(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
            }
        }
        return server
    }
}
