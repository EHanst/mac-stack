import Foundation
import MCP
import Observation
import os

/// Owns all async service actors and drives side-effectful operations
/// that AppCoordinator's pure reducer cannot perform directly.
@MainActor
@Observable
public final class AppServices {

    public let credentials = CredentialStore()
    public private(set) var workspaceName: String?
    private let registry = ModelRegistry()
    private var snapshotManager: GitSnapshotManager?
    private var indexingPipeline: IndexingPipeline?
    private var mcpService: MCPService?
    private var buildRunner: XPCBuildRunner?
    private var startupComplete = false
    /// Exactly what has been sent to the model this session; append-only so the local model's
    /// prefix cache stays valid across tool-loop turns and follow-up messages.
    private var ledger = PromptLedger()
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppServices")

    public init() {}

    public var isMCPRunning: Bool {
        get async { await mcpService?.isRunning ?? false }
    }

    // MARK: - Startup

    public func startup(coordinator: AppCoordinator, workspaceURL: URL? = nil) async {
        guard !startupComplete else { return }
        startupComplete = true

        if let url = workspaceURL ?? detectWorkspaceURL() {
            let mgr = GitSnapshotManager(workspaceURL: url)
            try? await mgr.open()
            snapshotManager = mgr
            workspaceName = url.lastPathComponent
        }

        let dbURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("VibeCockpit/index.db")
        if let dbURL {
            let store = VectorStore(dbURL: dbURL)
            let pipeline = IndexingPipeline(store: store, registry: registry)
            do {
                try await pipeline.open()
                indexingPipeline = pipeline
                if let workspaceURL = workspaceURL ?? detectWorkspaceURL() {
                    Task.detached(priority: .background) {
                        try? await pipeline.reindexWorkspace(workspaceURL)
                    }
                }
            } catch {
                logger.error("IndexingPipeline open failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        await credentials.registerEnvVarKey("BRAVE_SEARCH_API_KEY", for: "brave-search")

        let remoteConfigs = (try? ModelRegistry.loadRemoteConfigs()) ?? []
        let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("VibeCockpit/Models")
        try? await registry.discover(
            localDirectory: modelsDir,
            remoteConfigs: remoteConfigs,
            credentials: credentials
        )

        let providers = await registry.allProviders(with: .textGeneration)
        for provider in providers {
            let health = await provider.healthCheck()
            coordinator.send(.providerStatusChanged(provider.id, health))
        }

        if await registry.isEmpty {
            coordinator.send(.onboardingRequired)
        }

        // Pre-warm local providers in the background so they're healthy before first use.
        let localProviders = await registry.allProviders(with: .textGeneration)
            .filter { $0.id.hasPrefix("local:") }
        Task.detached(priority: .background) { [weak self] in
            for provider in localProviders {
                if let local = provider as? LocalMLXProvider {
                    try? await local.warmUp()
                    let health = await local.healthCheck()
                    await self?.notifyHealth(provider.id, health, coordinator: coordinator)
                }
            }
        }

        // Start embedded MCP server if we have a workspace
        if let workspaceURL = workspaceURL ?? detectWorkspaceURL(),
           let pipeline = indexingPipeline,
           let gitMgr = snapshotManager {
            let runner = XPCBuildRunner()
            await runner.connect()
            buildRunner = runner
            let ctx = WorkspaceContext(
                root: workspaceURL,
                workspaceID: WorkspaceID(rawValue: workspaceURL.lastPathComponent),
                policy: .default
            )
            let boundary = WorkspaceBoundary(context: ctx)
            let runtime = ToolRuntime(boundary: boundary, buildRunner: runner,
                                      gitManager: gitMgr, pipeline: pipeline)
            let socketDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vibecockpit")
            let socketPath = socketDir.appendingPathComponent("mcp.sock").path
            let service = MCPService(runtime: runtime, pipeline: pipeline, gitManager: gitMgr)
            do {
                try await service.start(socketPath: socketPath)
                mcpService = service
                await refreshMCPTools(coordinator: coordinator)
            } catch {
                logger.error("MCPService failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Populate model info list for the model manager UI.
        await refreshModels(coordinator: coordinator)
    }

    public func stopMCPService() async {
        await mcpService?.stop()
        mcpService = nil
    }

    // MARK: - Model management

    /// Refresh model info list and push to coordinator.
    public func refreshModels(coordinator: AppCoordinator) async {
        let providers = await registry.allProviders
        var infos: [ModelInfo] = []
        for provider in providers {
            let health = await provider.healthCheck()
            let kind: ModelInfo.Kind = provider.id.hasPrefix("local:") ? .local : .remote
            let displayName = provider.id.hasPrefix("local:")
                ? String(provider.id.dropFirst("local:".count))
                : provider.id
            let info = ModelInfo(
                id: provider.id,
                displayName: displayName,
                kind: kind,
                capabilities: provider.capabilities,
                health: health,
                isLoaded: health == .healthy
            )
            infos.append(info)
        }
        coordinator.send(.modelsRefreshed(infos))
        for info in infos {
            coordinator.send(.providerStatusChanged(info.id, info.health))
        }
    }

    private func notifyHealth(_ id: ProviderID, _ health: ProviderHealth, coordinator: AppCoordinator) {
        coordinator.send(.providerStatusChanged(id, health))
    }

    /// Unregister a local model provider by ID.
    public func unregisterModel(id: ProviderID, coordinator: AppCoordinator) async {
        await registry.unregister(id: id)
        await refreshModels(coordinator: coordinator)
    }

    /// Expose MCP tool names to the UI.
    public func refreshMCPTools(coordinator: AppCoordinator) async {
        coordinator.send(.mcpToolsUpdated([]))
    }

    // MARK: - Inference

    public func processIntent(_ text: String, coordinator: AppCoordinator) async {
        guard let provider = await registry.preferredProvider(for: .textGeneration) else {
            coordinator.send(.generationFailed("No model provider configured. Complete onboarding first."))
            coordinator.send(.generationFinished)
            return
        }

        coordinator.send(.generationStarted)

        let ragContext = await retrieveContext(for: text)
        let intent = PromptEngineer.classify(text)

        let agentTools: [AgentToolHandler] = [
            FileReaderTool(),
            FileWriterTool(),
            WebFetchTool(),
            WebSearchTool(credentials: credentials),
        ]
        let toolDefs = agentTools.map { ToolDefinition($0.toolDefinition) }

        // Build the augmented user message once and store it verbatim (item 1: append-only).
        let promptCount = coordinator.state.intentHistory.filter { $0.kind == .userPrompt }.count
        if ledger.userTurns + 1 != promptCount {
            // New or cleared session (or out of sync): start fresh, seeding from visible history.
            ledger.reset()
            var prior = historyMessages(coordinator.state)
            if prior.last?.role == .user { prior.removeLast() }   // the prompt being sent now
            ledger.begin(system: buildSystemPrompt(), prior: prior)
        } else if ledger.isEmpty {
            ledger.begin(system: buildSystemPrompt())
        }
        ledger.appendUserTurn(PromptEngineer.augmentUserTurn(text, intent: intent, ragContext: ragContext))
        // Budget: ~80% of maxTokens, approximated as chars/4. Drops whole old turns permanently.
        ledger.trim(toCharacterBudget: (GenerationOptions().maxTokens * 4 * 4) / 5)

        do {
            var continueLoop = true
            while continueLoop {
                let stream = await provider.generate(
                    messages: ledger.messages, tools: toolDefs, options: GenerationOptions())
                var pendingToolCalls: [ToolCall] = []
                var assistantText = ""
                do {
                    for try await event in stream {
                        switch event {
                        case .token(let t):
                            assistantText += t
                            coordinator.send(.tokenReceived(t))
                        case .toolCall(let call):
                            coordinator.send(.toolCallMade(call.name, call.arguments, call.id))
                            pendingToolCalls.append(call)
                        case .finished:
                            break
                        }
                    }
                } catch {
                    ledger.appendAssistant(assistantText)   // keep what the model already said
                    throw error
                }
                ledger.appendAssistant(assistantText)
                if pendingToolCalls.isEmpty {
                    continueLoop = false
                } else {
                    for call in pendingToolCalls {
                        let result = await executeTool(call, handlers: agentTools)
                        coordinator.send(.toolResultReceived(call.id, result))
                        ledger.appendToolResult(id: call.id, content: result)
                    }
                }
            }
        } catch {
            coordinator.send(.generationFailed(error.localizedDescription))
        }

        coordinator.send(.generationFinished)
    }

    private func executeTool(_ call: ToolCall, handlers: [AgentToolHandler]) async -> String {
        guard let handler = handlers.first(where: { $0.toolDefinition.name == call.name }) else {
            return "Unknown tool: \(call.name)"
        }
        do {
            let args = parseToolArguments(call.arguments)
            let contents = try await handler.execute(arguments: args)
            return contents.compactMap { item -> String? in
                if case .text(let t, _, _) = item { return t } else { return nil }
            }.joined(separator: "\n")
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    private func parseToolArguments(_ json: String) -> [String: MCP.Value] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj.compactMapValues { anyToMCPValue($0) }
    }

    private func anyToMCPValue(_ value: Any) -> MCP.Value? {
        switch value {
        case let s as String:  return .string(s)
        case let i as Int:     return .int(i)
        case let b as Bool:    return .bool(b)
        case let d as Double:  return .double(d)
        default:               return nil
        }
    }

    // MARK: - Onboarding helpers

    public func registerLocalModel(at url: URL, coordinator: AppCoordinator) async {
        try? await registry.discover(localDirectory: url, remoteConfigs: [], credentials: credentials)
        if await !registry.isEmpty {
            coordinator.send(.onboardingCompleted)
        }
    }

    public func saveCredentialAndComplete(
        token: String,
        providerID: ProviderID,
        baseURL: URL,
        coordinator: AppCoordinator
    ) async throws {
        try await credentials.store(token: token, for: providerID)
        let envKey = "VIBECOCKPIT_\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_TOKEN"
        let config = RemoteAPIProvider.Config(
            id: providerID,
            baseURL: baseURL,
            modelIdentifier: "",
            capabilities: [.textGeneration, .streaming],
            apiStyle: .openAIChat,
            envVarKey: envKey
        )
        try? await registry.discover(localDirectory: nil, remoteConfigs: [config], credentials: credentials)
        coordinator.send(.onboardingCompleted)
    }

    // MARK: - Snapshot operations

    public func diffAgainstSnapshot(_ ref: SnapshotRef, coordinator: AppCoordinator) async {
        guard let mgr = snapshotManager else { return }
        do {
            let diff = try await mgr.diffAgainstSnapshot(ref)
            coordinator.send(.diffUpdated(diff))
        } catch {
            logger.error("Diff failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func restoreSnapshot(_ ref: SnapshotRef, coordinator: AppCoordinator) async {
        guard let mgr = snapshotManager else { return }
        do {
            try await mgr.restoreSnapshot(ref)
        } catch {
            coordinator.send(.generationFailed("Restore failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - RAG retrieval

    private func retrieveContext(for query: String) async -> String? {
        guard let pipeline = indexingPipeline else { return nil }
        do {
            let results = try await pipeline.search(query: query, topK: 5)
            guard !results.isEmpty else { return nil }
            var lines = ["Relevant code from the workspace:"]
            for result in results {
                let fileName = URL(fileURLWithPath: result.filePath).lastPathComponent
                lines.append("// \(fileName) — \(result.declarationKind)")
                lines.append(result.content)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            logger.debug("RAG search failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private helpers

    /// Conversation so far as plain messages, reconstructed from UI events. Only used to seed
    /// the ledger when a session is rebuilt; earlier turns lose their RAG/framing here.
    private func historyMessages(_ state: AppState) -> [Message] {
        var candidates: [Message] = []
        var pendingAssistant = ""
        for event in state.intentHistory.reversed() {
            switch event.kind {
            case .assistantToken:
                pendingAssistant = event.content + pendingAssistant
            case .userPrompt:
                if !pendingAssistant.isEmpty {
                    candidates.insert(Message(role: .assistant, content: pendingAssistant), at: 0)
                    pendingAssistant = ""
                }
                candidates.insert(Message(role: .user, content: event.content), at: 0)
            case .toolResult:
                if !pendingAssistant.isEmpty {
                    candidates.insert(Message(role: .assistant, content: pendingAssistant), at: 0)
                    pendingAssistant = ""
                }
                candidates.insert(
                    Message(role: .tool, content: event.content, toolCallID: event.toolCallID),
                    at: 0
                )
            case .toolCall, .error:
                break
            }
        }
        if !pendingAssistant.isEmpty {
            candidates.insert(Message(role: .assistant, content: pendingAssistant), at: 0)
        }

        return candidates
    }

    private func buildSystemPrompt() -> String {
        var lines = [
            "You are VibeCockpit, an AI coding assistant. Help the user build and modify macOS Swift applications.",
        ]
        if let workspace = detectWorkspaceURL() {
            lines.append("Workspace root: \(workspace.path)")
        }
        if let swiftVersion = cachedSwiftVersion() {
            lines.append("Swift version: \(swiftVersion)")
        }
        if snapshotManager != nil {
            lines.append("Git snapshots are available. Prefer small, focused edits.")
        }
        return lines.joined(separator: "\n")
    }

    private func cachedSwiftVersion() -> String? {
        // Best-effort: runs only in background; nil is a safe no-op for the system prompt
        return nil
    }

    private func detectWorkspaceURL() -> URL? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<10 {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return nil
    }
}
