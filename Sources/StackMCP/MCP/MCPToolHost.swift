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
    private var noRoots = false
    public init(_ scopes: Set<ClientScope>, identity: ClientIdentity = .unknownLocalApp) { value = scopes; who = identity }
    /// Who is on the other end (a local tool learns its name when it introduces itself).
    public var identity: ClientIdentity {
        get { lock.withLock { who } }
        set { lock.withLock { who = newValue } }
    }
    /// Set once the client failed to answer a roots request; we don't ask again on this connection.
    public var rootsUnsupported: Bool {
        get { lock.withLock { noRoots } }
        set { lock.withLock { noRoots = newValue } }
    }
    public var scopes: Set<ClientScope> {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Resumes a continuation exactly once, whichever of two racing tasks gets there first.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in defer { continuation = nil }; return continuation }
        c?.resume(returning: value)
    }
}

/// The tools Kokoro offers over MCP, and a factory for one `Server` per connected client.
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
    private var briefProvider: (@Sendable () async -> [Brief])?
    private var workspaceOpener: (@Sendable (URL) async throws -> Void)?
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

    /// Called when a client works in a folder that isn't an open project; opens it as one.
    public func setWorkspaceOpener(_ opener: (@Sendable (URL) async throws -> Void)?) { workspaceOpener = opener }

    fileprivate func openWorkspace(_ url: URL) async -> Bool {
        guard let workspaceOpener else { return false }
        do { try await workspaceOpener(url); return true }
        catch { log.error("couldn't open \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"); return false }
    }

    /// The saved prompts offered to apps allowed to read them (MCP `prompts/list` and `prompts/get`).
    public func setPromptProvider(_ provider: (@Sendable () async -> [SavedPrompt])?) { promptProvider = provider }

    /// The briefs offered to apps allowed to read them (`list_briefs`, `get_brief`).
    public func setBriefProvider(_ provider: (@Sendable () async -> [Brief])?) { briefProvider = provider }

    fileprivate func prompts() async -> [SavedPrompt] { await promptProvider?() ?? [] }

    public func allTools() async -> [any AgentToolHandler] {
        var tools: [any AgentToolHandler] = []
        if let inference {
            let gateway = QueryGateway(inference: inference)
            tools += [ListModelsTool(gateway: gateway), ChatTool(gateway: gateway), EmbedTool(gateway: gateway),
                       OptimizePromptTool(inference: inference)]
        }
        if let briefProvider { tools += [ListBriefsTool(provider: briefProvider), GetBriefTool(provider: briefProvider)] }
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

    private static func isBlank(_ v: Value?) -> Bool {
        guard let v else { return true }
        if case .string(let s) = v { return s.isEmpty }
        return false
    }

    /// The folders the connected app says it is working in. Empty if it doesn't offer any.
    private static func rootPaths(of server: Server, scopes: ScopeBox) async -> [String] {
        // A client that answers "not supported" is remembered and not asked again. One that hasn't
        // answered in 5s (a slow start, or a client ignoring the request, which can't be cancelled) is
        // not remembered: this call goes on without a folder hint and the next call asks again.
        guard !scopes.rootsUnsupported else { return [] }
        let outcome: Result<[Root], Error>? = await withCheckedContinuation { continuation in
            let once = OneShot(continuation)
            Task {
                do { once.resume(.success(try await server.listRoots())) }
                catch { once.resume(.failure(error)) }
            }
            Task { try? await Task.sleep(for: .seconds(5)); once.resume(nil) }
        }
        var roots: [Root] = []
        switch outcome {
        case .success(let r)?: roots = r
        case .failure?: scopes.rootsUnsupported = true
        case nil: break
        }
        return roots.compactMap { r in
            guard let url = URL(string: r.uri), url.isFileURL, !url.path.isEmpty else { return nil }
            return url.path
        }
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
            title: "Kokoro",
            instructions: "The AI model running in Kokoro on this Mac (chat, embeddings, model list), plus code search, files, builds and snapshots when a project is open.",
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
                throw MCPError.invalidParams("This app isn't allowed to read your saved prompts. Change its permissions in Kokoro.")
            }
            guard let prompt = await host.prompts().first(where: { Self.promptName($0) == params.name }) else {
                throw MCPError.invalidParams("Unknown prompt: \(params.name)")
            }
            let text = Self.renderPrompt(prompt, arguments: params.arguments ?? [:])
            return GetPrompt.Result(description: prompt.title, messages: [.user(.text(text: text))])
        }

        await server.withMethodHandler(CallTool.self) { params in
            let tools = await host.allTools()
            guard var handler = tools.first(where: { $0.toolDefinition.name == params.name }) else {
                throw MCPError.methodNotFound("Unknown tool: \(params.name)")
            }
            guard scopes.scopes.contains(handler.requiredScope) else {
                return CallTool.Result(
                    content: [.text(text: "This app isn't allowed to \(handler.requiredScope.title.lowercased()). Change its permissions in Kokoro.", annotations: nil, _meta: nil)],
                    isError: true)
            }
            // Project tools default to the folder the calling app is working in (its MCP "roots").
            var arguments = params.arguments ?? [:]
            if let routed = handler as? WorkspaceRoutedTool, Self.isBlank(arguments["workspace"]) {
                switch routed.match(rootPaths: await Self.rootPaths(of: server, scopes: scopes)) {
                case .matched(let id)?:
                    arguments["workspace"] = .string(id)
                case .unmatched(let paths)?:
                    // The client is working in a folder Kokoro doesn't have open yet: open it, then use it.
                    var opened = false
                    for path in paths where await host.openWorkspace(URL(fileURLWithPath: path)) { opened = true }
                    if opened, let fresh = await host.allTools().first(where: { $0.toolDefinition.name == params.name }),
                       let freshRouted = fresh as? WorkspaceRoutedTool, case .matched(let id)? = freshRouted.match(rootPaths: paths) {
                        handler = fresh
                        arguments["workspace"] = .string(id)
                        break
                    }
                    return CallTool.Result(
                        content: [.text(text: "'\(paths.joined(separator: ", "))' isn't an open project in Kokoro. Add it in the app, or name an open project with the 'workspace' argument.", annotations: nil, _meta: nil)],
                        isError: true)
                case nil:
                    break
                }
            }
            let target = handler   // fixed from here on (it may have been replaced after opening a folder)
            let callArguments = arguments
            // Write and exec always ask an outside app; after web/other-program content, "Always allow" no longer counts.
            if let refusal = await toolGuard.refusal(
                for: target, arguments: callArguments, client: scopes.identity,
                context: untrusted, alwaysAsk: true) {
                return CallTool.Result(content: [.text(text: refusal, annotations: nil, _meta: nil)], isError: true)
            }
            let opID = OperationID()
            let task = Task<[Tool.Content], Error> { try await target.execute(arguments: callArguments) }
            if let runtime {
                await runtime.trackTask(opID, task: Task<Void, Error> { _ = try await task.value })
            }
            func finish() async { if let runtime { await runtime.removeTask(opID) } }
            do {
                let content = toolGuard.filter(try await task.value, from: target, context: untrusted)
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
