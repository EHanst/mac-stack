import Foundation
import MCP
import Observation
import os
#if SWIFT_PACKAGE
import StackCore
#if SWIFT_PACKAGE
import StackMCP
#endif
#endif

/// Owns all async service actors and drives side-effectful operations
/// that AppCoordinator's pure reducer cannot perform directly.
@MainActor
@Observable
public final class AppServices {

    public let credentials = CredentialStore()
    /// The local OpenAI-compatible API and the apps allowed to use it (off by default).
    public let sharing: APISharingModel
    public private(set) var workspaceName: String?
    private let registry: ModelRegistry
    /// All text generation goes through here: routing policy, GPU scheduling, fallback.
    private let inference: InferenceService
    /// One GPU, one queue: chat generation and local embeddings both go through this.
    private let gpuScheduler = InferenceScheduler()
    private let installer = ModelInstaller()
    private var snapshotManager: GitSnapshotManager?
    private var indexingPipeline: IndexingPipeline?
    private var mcpService: MCPService?
    private var buildRunner: XPCBuildRunner?
    private var startupComplete = false
    /// Exactly what has been sent to the model this session; append-only so the local model's
    /// prefix cache stays valid across tool-loop turns and follow-up messages.
    private var ledger = PromptLedger()
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppServices")

    /// Local only / Local first / Cloud allowed. Observable so the menu bar and Settings agree.
    public private(set) var routingPolicy: RoutingPolicy
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        let registry = ModelRegistry()
        self.registry = registry
        self.defaults = defaults
        let policy = defaults.string(forKey: Self.policyKey).flatMap(RoutingPolicy.init(rawValue:)) ?? .localFirst
        self.routingPolicy = policy
        let inference = InferenceService(registry: registry, scheduler: gpuScheduler, policy: policy)
        self.inference = inference
        self.sharing = APISharingModel(inference: inference, defaults: defaults)
    }

    private static let policyKey = "routingPolicy"
    /// Our own cap on conversation size (the model's native window is 262,144; see docs/plans/model-facts.md).
    private static let contextTokenBudget = 64_000

    /// Local only / Local first / Cloud allowed. Persisted; takes effect on the next request.
    public func setRoutingPolicy(_ policy: RoutingPolicy) async {
        routingPolicy = policy
        defaults.set(policy.rawValue, forKey: Self.policyKey)
        await inference.setPolicy(policy)
    }

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

        await registerEmbedderIfInstalled()

        // Other apps may ask for models as soon as the server is up, so start it once they're registered.
        await sharing.startIfEnabled()

        let providers = await registry.allProviders(with: .textGeneration)
        for provider in providers {
            let health = await provider.healthCheck()
            coordinator.send(.providerStatusChanged(provider.id, health))
        }

        // Onboarding is about having something to *chat* with; the embedder alone doesn't count.
        if await registry.allProviders(with: .textGeneration).isEmpty {
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
        // Budget: the smaller of ~80% of maxTokens and what this Mac can hold right now
        // (provider-reported, tokens → chars at a conservative 2.5 chars/token). Drops whole old
        // turns permanently so the prompt stays append-only afterwards.
        var charBudget = (Self.contextTokenBudget * 4 * 4) / 5
        if let limit = await inference.localContextLimit() {
            charBudget = min(charBudget, Int(Double(limit) * 2.5 * 0.9))
        }
        ledger.trim(toCharacterBudget: charBudget)

        do {
            var continueLoop = true
            while continueLoop {
                let stream = try await inference.generate(
                    messages: ledger.messages, tools: toolDefs, options: GenerationOptions(),
                    priority: .interactive)
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
                        case .usage, .finished:
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
        if await !registry.allProviders(with: .textGeneration).isEmpty {
            coordinator.send(.onboardingCompleted)
        }
    }

    /// Offline embeddings (bge-small) if installed; shares the GPU scheduler. Safe to call twice.
    private func registerEmbedderIfInstalled() async {
        let embedder = LocalEmbedder(scheduler: gpuScheduler)
        guard await embedder.isInstalled, await registry.provider(id: embedder.id) == nil else { return }
        await registry.register(embedder)
        for provider in await registry.allProviders(with: .textGeneration) {
            await (provider as? LocalMLXProvider)?.reserveMemory(bytes: LocalEmbedder.residentBytesEstimate)
        }
    }

    // MARK: - First-run setup

    /// The first-run model: what this Mac can do, and the installer that makes it so.
    public func makeSetupModel(coordinator: AppCoordinator) async -> SetupModel {
        var installed = Set<String>()
        for entry in ModelCatalog.all where await installer.state(of: entry) == .installed {
            installed.insert(entry.id)
        }
        let hardware = HardwareProfile.current(installRoot: ModelInstaller.defaultRoot())
        let plan = SetupPlan.make(for: hardware, installed: installed)
        let gib = Double(hardware.physicalMemoryBytes) / 1_073_741_824
        let installer = self.installer
        return SetupModel(
            plan: plan,
            hardwareLine: "\(hardware.chipName) · \(Int(gib.rounded())) GB memory",
            install: { entry, progress in try await installer.install(entry, progress: progress) },
            onFinished: { [weak self] in await self?.finishLocalInstall(coordinator: coordinator) })
    }

    /// After the downloads: pick up the new models, start loading the chat model, leave onboarding.
    private func finishLocalInstall(coordinator: AppCoordinator) async {
        let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("VibeCockpit/Models")
        try? await registry.discover(localDirectory: modelsDir, remoteConfigs: [], credentials: credentials)
        await registerEmbedderIfInstalled()
        await refreshModels(coordinator: coordinator)
        if await !registry.allProviders(with: .textGeneration).isEmpty {
            coordinator.send(.onboardingCompleted)
        }
        let local = await registry.allProviders(with: .textGeneration).compactMap { $0 as? LocalMLXProvider }
        Task.detached(priority: .background) { [weak self] in
            for provider in local {
                try? await provider.warmUp()
                let health = await provider.healthCheck()
                await self?.notifyHealth(provider.id, health, coordinator: coordinator)
            }
        }
    }

    public func saveCredentialAndComplete(
        token: String,
        providerID: ProviderID,
        baseURL: URL,
        modelIdentifier: String,
        coordinator: AppCoordinator
    ) async throws {
        try await credentials.store(token: token, for: providerID)
        let envKey = "VIBECOCKPIT_\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_TOKEN"
        let config = RemoteAPIProvider.Config(
            id: providerID,
            baseURL: baseURL,
            modelIdentifier: modelIdentifier,
            capabilities: [.textGeneration, .streaming],
            apiStyle: baseURL.host == "api.anthropic.com" ? .anthropicMessages : .openAIChat,
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
    private func historyMessages(_ state: AppState) -> [ChatMessage] {
        var candidates: [ChatMessage] = []
        var pendingAssistant = ""
        for event in state.intentHistory.reversed() {
            switch event.kind {
            case .assistantToken:
                pendingAssistant = event.content + pendingAssistant
            case .userPrompt:
                if !pendingAssistant.isEmpty {
                    candidates.insert(ChatMessage(role: .assistant, content: pendingAssistant), at: 0)
                    pendingAssistant = ""
                }
                candidates.insert(ChatMessage(role: .user, content: event.content), at: 0)
            case .toolResult:
                if !pendingAssistant.isEmpty {
                    candidates.insert(ChatMessage(role: .assistant, content: pendingAssistant), at: 0)
                    pendingAssistant = ""
                }
                candidates.insert(
                    ChatMessage(role: .tool, content: event.content, toolCallID: event.toolCallID),
                    at: 0
                )
            case .toolCall, .error:
                break
            }
        }
        if !pendingAssistant.isEmpty {
            candidates.insert(ChatMessage(role: .assistant, content: pendingAssistant), at: 0)
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
