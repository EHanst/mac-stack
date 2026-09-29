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
    private var who: ClientIdentity
    public init(_ scopes: Set<ClientScope>, identity: ClientIdentity = .unknownLocalApp) { value = scopes; who = identity }
    /// Who is on the other end (a local tool learns its name when it introduces itself).
    public var identity: ClientIdentity {
        get { lock.withLock { who } }
        set { lock.withLock { who = newValue } }
    }
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
    private let gate: ToolGate?
    private var workspaceTools: [any AgentToolHandler] = []
    private var runtime: ToolRuntime?
    private var projectTools: (@Sendable () async -> [any AgentToolHandler])?
    private var externalTools: (@Sendable () async -> [any AgentToolHandler])?
    private var promptProvider: (@Sendable () async -> [SavedPrompt])?
    private let log = Logger(subsystem: "com.vibecockpit", category: "MCPToolHost")

    /// `gate` decides whether an app may change files or run commands; without one those are refused.
    public init(inference: InferenceService? = nil, gate: ToolGate? = nil) {
        self.inference = inference
        self.gate = gate
    }

    public var hasWorkspace: Bool { runtime != nil }

    /// Adds the code-search, file, build and snapshot tools. Applies to connections made afterwards.
    public func attachWorkspace(runtime: ToolRuntime, pipeline: IndexingPipeline, gitManager: GitSnapshotManager) {
        self.runtime = runtime
        workspaceTools = Self.workspaceTools(runtime: runtime, pipeline: pipeline, gitManager: gitManager)
    }

    /// The code-search, file, build and snapshot tools for one project.
    public static func workspaceTools(runtime: ToolRuntime, pipeline: IndexingPipeline, gitManager: GitSnapshotManager) -> [any AgentToolHandler] {
        [
            SearchCodeTool(pipeline: pipeline),
            RuntimeIndexWorkspaceTool(runtime: runtime),
            RuntimeFileReaderTool(runtime: runtime),
            RuntimeFileWriterTool(runtime: runtime),
            RuntimeRunBuildTool(runtime: runtime),
            SnapshotCreateTool(manager: gitManager),
            SnapshotDiffTool(manager: gitManager),
        ]
    }

    /// Adds one more tool (applies to connections made afterwards).
    public func register(_ tool: any AgentToolHandler) { workspaceTools.append(tool) }

    /// Tools from external MCP servers the user added; asked for on every list and call, so servers
    /// that start later show up without reconnecting.
    /// Tools for every project the user opened (see `WorkspaceManager`); asked for on every list and call.
    public func setProjectTools(_ provider: (@Sendable () async -> [any AgentToolHandler])?) { projectTools = provider }

    public func setExternalTools(_ provider: (@Sendable () async -> [any AgentToolHandler])?) { externalTools = provider }

    /// The saved prompts offered to apps allowed to read them (MCP `prompts/list` and `prompts/get`).
    public func setPromptProvider(_ provider: (@Sendable () async -> [SavedPrompt])?) { promptProvider = provider }

    fileprivate func prompts() async -> [SavedPrompt] { await promptProvider?() ?? [] }

    public func allTools() async -> [any AgentToolHandler] {
        var tools: [any AgentToolHandler] = []
        if let inference {
            tools += [ListModelsTool(inference: inference), ChatTool(inference: inference), EmbedTool(inference: inference),
                       OptimizePromptTool(inference: inference)]
        }
        return tools + workspaceTools + (await projectTools?() ?? []) + (await externalTools?() ?? [])
    }

    // MARK: Prompts

    /// The name other apps use: the shortcut if there is one, else the id.
    static func promptName(_ p: SavedPrompt) -> String { p.slash ?? p.id }

    /// Every blank is an argument, except `date`, which is filled in here. `clipboard` is *not* read for
    /// outside apps: they have to pass it, so a connected app can't quietly read what you copied.
    static func mcpPrompt(_ p: SavedPrompt) -> Prompt {
        let blanks = PromptTemplate.variables(in: p.body).filter { $0 != "date" }
        let first = p.body.split(separator: "\n").first.map(String.init) ?? p.title
        return Prompt(
            name: promptName(p), title: p.title, description: first.count > 140 ? String(first.prefix(140)) + "…" : first,
            arguments: blanks.map { Prompt.Argument(name: $0, required: false) })
    }

    static func renderPrompt(_ p: SavedPrompt, arguments: [String: String]) -> String {
        var values = arguments
        if PromptTemplate.variables(in: p.body).contains("date") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            values["date"] = f.string(from: Date())
        }
        return PromptTemplate.render(p.body, values: values)
    }

    /// A server for one client. `scopes` is consulted on every list and call.
    public func makeServer(scopes: ScopeBox) async -> Server {
        let host = self
        let runtime = self.runtime
        let toolGuard = ToolCallGuard(gate: self.gate)
        let untrusted = UntrustedContext()   // per connection: what this client has been handed from outside
        let log = self.log
        let server = Server(
            name: "vibecockpit",
            version: "1.0.0",
            title: "VibeCockpit",
            instructions: "The AI model running in VibeCockpit on this Mac (chat, embeddings, model list), plus code search, files, builds and snapshots when a project is open.",
            capabilities: Server.Capabilities(prompts: .init(), tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            let tools = await host.allTools()
            let allowed = scopes.scopes
            return ListTools.Result(tools: tools.filter { allowed.contains($0.requiredScope) }.map { $0.toolDefinition.withValidSchema })
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            guard scopes.scopes.contains(.prompts) else { return ListPrompts.Result(prompts: []) }
            return ListPrompts.Result(prompts: await host.prompts().map(Self.mcpPrompt))
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            guard scopes.scopes.contains(.prompts) else {
                throw MCPError.invalidParams("This app isn't allowed to read your saved prompts. Change its permissions in VibeCockpit.")
            }
            guard let prompt = await host.prompts().first(where: { Self.promptName($0) == params.name }) else {
                throw MCPError.invalidParams("Unknown prompt: \(params.name)")
            }
            let text = Self.renderPrompt(prompt, arguments: params.arguments ?? [:])
            return GetPrompt.Result(description: prompt.title, messages: [.user(.text(text: text))])
        }

        await server.withMethodHandler(CallTool.self) { params in
            let tools = await host.allTools()
            guard let handler = tools.first(where: { $0.toolDefinition.name == params.name }) else {
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
            guard scopes.scopes.contains(handler.requiredScope) else {
                return CallTool.Result(
                    content: [.text(text: "This app isn't allowed to \(handler.requiredScope.title.lowercased()). Change its permissions in VibeCockpit.", annotations: nil, _meta: nil)],
                    isError: true)
            }
            // Write and exec always ask an outside app; after web/other-program content, "Always allow" no longer counts.
            if let refusal = await toolGuard.refusal(
                for: handler, arguments: params.arguments ?? [:], client: scopes.identity,
                context: untrusted, alwaysAsk: true) {
                return CallTool.Result(content: [.text(text: refusal, annotations: nil, _meta: nil)], isError: true)
            }
            let opID = OperationID()
            let task = Task<[Tool.Content], Error> { try await handler.execute(arguments: params.arguments ?? [:]) }
            if let runtime {
                await runtime.trackTask(opID, task: Task<Void, Error> { _ = try await task.value })
            }
            func finish() async { if let runtime { await runtime.removeTask(opID) } }
            do {
                let content = toolGuard.filter(try await task.value, from: handler, context: untrusted)
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
