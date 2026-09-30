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
    /// Questions from outside apps that want to change files or run commands.
    public let approvals = ApprovalCenter()
    public let savedApprovals: SavedApprovalsModel
    public private(set) var workspaceName: String?
    private let registry: ModelRegistry
    /// All text generation goes through here: routing policy, GPU scheduling, fallback.
    private let inference: InferenceService
    /// One GPU, one queue: chat generation and local embeddings both go through this.
    private let gpuScheduler = InferenceScheduler()
    /// Every outbound request passes this: privacy switch, monthly cloud limit, "what left" record.
    public let egress: EgressGate
    public let cloudUsage: CloudUsageModel
    private let governor = SystemGovernor()
    /// Memory pressure, heat and Low Power Mode, for the menu and for routing.
    public private(set) var systemLoad = SystemLoad()
    private let installer: ModelInstaller
    private var snapshotManager: GitSnapshotManager?
    private var indexingPipeline: IndexingPipeline?
    /// The tools offered to MCP clients; one instance for the Unix socket and the HTTP endpoint.
    private let mcpHost: MCPToolHost
    private var mcpService: MCPService?
    private var startupComplete = false
    /// Exactly what has been sent to the model this session; append-only so the local model's
    /// prefix cache stays valid across tool-loop turns and follow-up messages.
    private var ledger = PromptLedger()
    /// A summary being written in the background after a turn; cancelled when the next send starts.
    private var compactionTask: Task<Void, Never>?
    /// Characters per token learned from the model's own token counts (starts at the pessimistic 2.5).
    private var calibration = TokenCalibration()
    /// Outside content (web pages, search results) seen in this conversation; see `ToolCallGuard`.
    private let untrusted = UntrustedContext()
    private let toolGuard: ToolCallGuard
    /// External MCP servers the user added; their tools join the model's and our own `tools/list`.
    public let externalServers = MCPClientManager()
    /// Project folders the user added; each has its own index, git and boundary.
    public let workspaces: WorkspaceManager
    /// Saved prompts and the editable per-task guidance (recipes).
    public let promptLibrary: PromptLibrary
    /// Save/insert/improve prompts from the chat box.
    public let promptStudio: PromptStudioModel
    let workspaceSearch: WorkspaceSearch
    public let briefs = BriefWorkbenchModel(store: BriefStore())
    /// Prompts committed inside project folders (`.vibe/prompts`); usable only after the user approves each.
    public let projectPrompts: WorkspacePromptStore
    public let requestLog = RequestLog(fileURL: RequestLog.defaultURL())
    public let diagnostics: DiagnosticsModel
    public let workspacesModel: WorkspacesModel
    public let externalServersModel: ExternalServersModel
    private static let chatIdentity = ClientIdentity(key: "app:chat", name: AppBrand.name)
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppServices")

    /// Local only / Local first / Cloud allowed. Observable so the menu bar and Settings agree.
    public private(set) var routingPolicy: RoutingPolicy
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        let registry = ModelRegistry()
        self.registry = registry
        let promptLibrary = PromptLibrary()
        self.promptLibrary = promptLibrary
        self.defaults = defaults
        let policy = defaults.string(forKey: Self.policyKey).flatMap(RoutingPolicy.init(rawValue:)) ?? .localFirst
        self.routingPolicy = policy
        let gate = EgressGate(policy: policy)
        self.egress = gate
        self.cloudUsage = CloudUsageModel(gate: gate)
        self.installer = ModelInstaller(gate: gate)
        let inference = InferenceService(registry: registry, scheduler: gpuScheduler, policy: policy, gate: gate, governor: governor, requestLog: requestLog)
        self.inference = inference
        let memory = ApprovalMemory()
        self.savedApprovals = SavedApprovalsModel(memory: memory)
        let runnerBox = SharedBuildRunner()
        let workspaceSearch = WorkspaceSearch()
        self.workspaceSearch = workspaceSearch
        let workspaces = WorkspaceManager { record in
            try await AppServices.openWorkspace(record, registry: registry, runner: runnerBox.get(), search: workspaceSearch)
        }
        self.workspaces = workspaces
        let projectPrompts = WorkspacePromptStore(roots: { await workspaces.list.map { ($0.record.name, $0.record.url) } })
        self.projectPrompts = projectPrompts
        self.promptStudio = PromptStudioModel(
            library: promptLibrary, optimizer: PromptOptimizer(inference: inference),
            plannedModel: { await inference.plannedModel() },
            listModels: { await inference.availableModels() },
            projectPrompts: projectPrompts,
            defaults: defaults)
        let externals = externalServers, requestLog = self.requestLog, governor = self.governor
        self.diagnostics = DiagnosticsModel(log: requestLog) {
            try await AppServices.makeSupportBundle(
                registry: registry, egress: gate, governor: governor, inference: inference,
                externals: externals, workspaces: workspaces, requestLog: requestLog)
        }
        self.workspacesModel = WorkspacesModel(manager: workspaces)
        let toolGate = ToolGate(memory: memory, approver: approvals)
        self.toolGuard = ToolCallGuard(gate: toolGate)
        let host = MCPToolHost(inference: inference, gate: toolGate)
        self.mcpHost = host
        self.externalServersModel = ExternalServersModel(manager: externals)
        Task {
            await host.setExternalTools { await externals.tools() }
            await host.setProjectTools { await workspaces.tools() }
            await host.setWorkspaceOpener { try await workspaces.add($0) }
            // Other apps see your own prompts plus project prompts you approved; nothing else.
            await host.setPromptProvider { await promptLibrary.userPrompts() + projectPrompts.approvedPrompts() }
        }
        self.sharing = APISharingModel(inference: inference, defaults: defaults, mcp: MCPHTTPSessions(host: host))
    }

    private static let policyKey = "routingPolicy"
    /// Our own cap on conversation size (the model's native window is 262,144; see docs/plans/model-facts.md).
    private static let contextTokenBudget = 64_000

    /// Local only / Local first / Cloud allowed. Persisted; takes effect on the next request.
    public func setRoutingPolicy(_ policy: RoutingPolicy) async {
        routingPolicy = policy
        defaults.set(policy.rawValue, forKey: Self.policyKey)
        await egress.setPolicy(policy)
        await inference.setPolicy(policy)
    }

    public var isMCPRunning: Bool {
        get async { await mcpService?.isRunning ?? false }
    }

    // MARK: - Startup

    public func startup(coordinator: AppCoordinator, workspaceURL: URL? = nil) async {
        guard !startupComplete else { return }
        startupComplete = true
        DiagnosticsCollector.shared.start()
        promptStudio.conversationPrefix = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return [] }
            return self.optimizerPrefix(promptCount: coordinator.state.intentHistory.filter { $0.kind == .userPrompt }.count)
        }
        await promptStudio.reload()
        briefs.contextSource = BriefContextSource(
            roots: { [workspaces] in await workspaces.list.map(\.record.url) },
            search: { [workspaceSearch] query in await workspaceSearch.search(query, limit: 8) },
            workingDiff: { try await GitDiffReader.workingDiff(in: $0) })
        await briefs.reload()
        await promptStudio.refreshModel()

        if let url = workspaceURL ?? detectWorkspaceURL() {
            let mgr = GitSnapshotManager(workspaceURL: url)
            try? await mgr.open()
            snapshotManager = mgr
            workspaceName = url.lastPathComponent
            promptStudio.workspaceName = url.lastPathComponent
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
                    await pipeline.watch(workspaceURL)
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
            credentials: credentials,
            gate: egress
        )

        await registerEmbedderIfInstalled()

        // Other apps may ask for models as soon as the server is up, so start it once they're registered.
        await sharing.startIfEnabled()
        await externalServers.startAll()
        await startGovernor()

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
            // The list the Models page and chat header read was built before the model loaded.
            await self?.refreshModels(coordinator: coordinator)
            await self?.prereadSystemPrompt()
        }

        // MCP: model tools are always offered; project tools join for every project the user opened
        // (plus the folder the app was started in, when that is a git checkout).
        if let url = workspaceURL ?? detectWorkspaceURL() { _ = try? await workspaces.add(url) }
        await workspaces.openAll()
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibecockpit/mcp.sock").path
        let service = MCPService(host: mcpHost)
        do {
            try await service.start(socketPath: socketPath)
            mcpService = service
            await refreshMCPTools(coordinator: coordinator)
        } catch {
            logger.error("MCPService failed to start: \(error.localizedDescription, privacy: .public)")
        }

        // Populate model info list for the model manager UI.
        await refreshModels(coordinator: coordinator)
    }

    /// On critical memory pressure the local model's saved prompt snapshots (big) are dropped;
    /// the next request just re-reads its prompt.
    private func startGovernor() async {
        let registry = self.registry
        await governor.onChange { [weak self] load in
            Task { @MainActor in self?.systemLoad = load }
            guard load.memory == .critical else { return }
            Task {
                for provider in await registry.allProviders(with: .textGeneration) {
                    await (provider as? LocalMLXProvider)?.clearPromptCache()
                }
            }
        }
        await governor.start()
        systemLoad = await governor.current
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
        infos = ModelListing.visible(infos)
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

    /// The support bundle: facts and timings only (see `SupportBundleInput`).
    nonisolated static func makeSupportBundle(
        registry: ModelRegistry, egress: EgressGate, governor: SystemGovernor, inference: InferenceService,
        externals: MCPClientManager, workspaces: WorkspaceManager, requestLog: RequestLog
    ) async throws -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let providers = await registry.allProviders
        let reports = DiagnosticsCollector.savedReports().map { SupportBundleInput.CrashReport(file: $0.file, json: $0.json) }
        let input = SupportBundleInput(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
            build: info["CFBundleVersion"] as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: String(cString: brand),
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            routingPolicy: await inference.policy.rawValue,
            systemLoad: await governor.current,
            installedModels: providers.filter(\.isLocal).map(\.id).sorted(),
            providers: providers.map { .init(id: $0.id, isLocal: $0.isLocal) }.sorted { $0.id < $1.id },
            requests: await requestLog.recent,
            egress: await egress.entries,
            tokensThisMonth: await egress.tokensThisMonth,
            monthlyTokenCap: await egress.monthlyTokenCap,
            externalServers: await externals.list.map { .init(name: $0.server.name, status: ExternalServersModel.statusText($0.status)) },
            projectCount: await workspaces.list.count,
            crashReports: reports)
        return try SupportBundle.make(input)
    }

    /// Builds one project's tools: its own git snapshots, its own search index, and a boundary
    /// that keeps file access and commands inside its folder.
    nonisolated static func openWorkspace(
        _ record: WorkspaceRecord, registry: ModelRegistry, runner: XPCBuildRunner, search: WorkspaceSearch
    ) async throws -> [any AgentToolHandler] {
        let url = record.url
        let git = GitSnapshotManager(workspaceURL: url)
        try? await git.open()   // not a git checkout: snapshot tools will say so when used
        let indexDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        let pipeline = IndexingPipeline(store: VectorStore(dbURL: indexDir.appendingPathComponent("\(record.id).db")), registry: registry)
        try await pipeline.open()
        await search.register(id: record.id) { query in try await pipeline.search(query: query, topK: 8) }
        Task.detached(priority: .background) { try? await pipeline.reindexWorkspace(url) }
        await pipeline.watch(url)
        let context = WorkspaceContext(root: url, workspaceID: WorkspaceID(rawValue: record.id), policy: .default)
        let runtime = ToolRuntime(boundary: WorkspaceBoundary(context: context), buildRunner: runner,
                                  gitManager: git, pipeline: pipeline)
        return MCPToolHost.workspaceTools(runtime: runtime, pipeline: pipeline, gitManager: git)
    }

    /// Expose MCP tool names to the UI.
    public func refreshMCPTools(coordinator: AppCoordinator) async {
        coordinator.send(.mcpToolsUpdated([]))
    }

    // MARK: - Inference

    public func processIntent(_ text: String, coordinator: AppCoordinator, intent intentOverride: PromptEngineer.Intent? = nil) async {
        compactionTask?.cancel()
        compactionTask = nil
        coordinator.send(.generationStarted)

        let composed = await composeUserTurn(text, intentOverride: intentOverride)

        let externalTools = await externalServers.tools()
        let agentTools: [AgentToolHandler] = externalTools + [
            FileReaderTool(),
            FileWriterTool(),
            WebFetchTool(gate: egress),
            WebSearchTool(credentials: credentials, gate: egress),
        ]
        let toolDefs = agentTools.map { ToolDefinition($0.toolDefinition) }

        // Build the augmented user message once and store it verbatim (item 1: append-only).
        let promptCount = coordinator.state.intentHistory.filter { $0.kind == .userPrompt }.count
        if ledger.userTurns + 1 != promptCount {
            // New or cleared session (or out of sync): start fresh, seeding from visible history.
            ledger.reset()
            untrusted.reset()
            var prior = historyMessages(coordinator.state)
            if prior.last?.role == .user { prior.removeLast() }   // the prompt being sent now
            ledger.begin(system: buildSystemPrompt(), prior: prior)
        } else if ledger.isEmpty {
            ledger.begin(system: buildSystemPrompt())
        }
        ledger.appendUserTurn(composed.turn)
        // Budget: the smaller of ~80% of maxTokens and what this Mac can hold right now
        // (provider-reported, tokens → chars at a conservative 2.5 chars/token). Drops whole old
        // turns permanently so the prompt stays append-only afterwards.
        var charBudget = (Self.contextTokenBudget * 4 * 4) / 5
        if let limit = await inference.localContextLimit() {
            charBudget = min(charBudget, Int(Double(limit) * calibration.charsPerToken * 0.9))
        }
        // Before dropping whole turns, clear old bulky tool output in one batch (cheaper, reversible,
        // and keeps the conversation). Only when this Mac's memory ceiling is what limits us.
        if let limit = await inference.localContextLimit() {
            let plan = CompactionPlanner().plan(items: ledger.compactionItems(calibration: calibration),
                                                maxPromptTokens: min(limit, Self.contextTokenBudget))
            if !plan.elide.isEmpty {
                let freed = ledger.elide(plan.elide, calibration: calibration)
                coordinator.send(.noticeShown("Cleared \(plan.elide.count) old tool result\(plan.elide.count == 1 ? "" : "s") from the model's view to make room (about \(freed) tokens). They stay visible here.", symbol: "scissors"))
            }
        }
        ledger.trim(toCharacterBudget: charBudget)

        do {
            var continueLoop = true
            while continueLoop {
                let load = await governor.current
                let sentChars = ledger.messages.reduce(0) { $0 + $1.content.count }
                let stream = try await inference.generate(
                    messages: ledger.messages, tools: toolDefs, options: GenerationOptions(),
                    priority: .interactive,
                    onRoute: { notice in
                        guard let text = Self.noticeText(notice, load: load) else { return }
                        Task { @MainActor in coordinator.send(.noticeShown(text)) }
                    })
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
                        case .usage(let usage):
                            calibration.observe(chars: sentChars, promptTokens: usage.promptTokens)
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
        await diagnostics.reload()
        await compactWhileIdle(coordinator: coordinator)
    }

    /// Right after the model loads, read the system prompt once so the first message finds it cached
    /// (the system entry of the prompt cache is never evicted). Skipped when the Mac is strained.
    private func prereadSystemPrompt() async {
        guard await !governor.current.isStrained, let localID = await inference.localTextProviderID() else { return }
        let system = Message(role: .system, content: buildSystemPrompt())
        guard let stream = try? await inference.generate(
            messages: [system], tools: [], options: GenerationOptions(maxTokens: 1),
            priority: .background, pin: localID) else { return }
        do { for try await _ in stream {} } catch {}
    }

    /// After a turn, while the chat is idle: if the prompt is getting near this Mac's ceiling, make
    /// the whole change now (clear old tool output and, if that isn't enough, summarize the oldest
    /// turns on the local model), then read the new prompt in the background so the next reply finds
    /// it cached instead of paying the re-read. One change means one cache rebuild, and it happens
    /// off the reply's critical path. The next send cancels all of it, so it never delays a message,
    /// and the send path still clears tool output itself if this didn't finish. Local model only:
    /// nothing leaves the Mac.
    private func compactWhileIdle(coordinator: AppCoordinator) async {
        guard let limit = await inference.localContextLimit(),
              let localID = await inference.localTextProviderID() else { return }
        // Hot, low on memory, or in Low Power Mode: keep to the cheap step (clearing tool output);
        // no summary and no background re-read.
        let strained = await governor.current.isStrained
        let planner = CompactionPlanner(allowSummarize: !strained)
        let plan = planner.plan(items: ledger.compactionItems(calibration: calibration),
                                maxPromptTokens: min(limit, Self.contextTokenBudget))
        guard plan.outcome != .none, !plan.elide.isEmpty || plan.summarize != nil else { return }
        let run = plan.summarize.map { Array(ledger.messages[$0]) }
        let keep = run.map { CompactionSummarizer.mustKeep(in: $0) } ?? []
        let part = CompactionSummarizer.partCount(in: ledger.messages) + 1
        let inference = self.inference
        let budget = planner.summaryTokens
        compactionTask = Task { [weak self] in
            var summary: String?
            if let run {
                var text = ""
                do {
                    // cacheSnapshots: false, so writing the summary can't evict the chat's cached prefix.
                    let stream = try await inference.generate(
                        messages: CompactionSummarizer.requestMessages(for: run), tools: [],
                        options: GenerationOptions(maxTokens: 700, cacheSnapshots: false),
                        priority: .background, pin: localID)
                    for try await event in stream { if case .token(let t) = event { text += t } }
                } catch { return }   // cancelled or failed: leave the chat as it is
                summary = CompactionSummarizer.finalize(summary: text, mustKeep: keep, maxTokens: budget, part: part)
            }
            guard !Task.isCancelled, let self else { return }
            // Apply everything in one step. Elision indices lie outside the summarized run.
            let cleared = self.ledger.elide(plan.elide, calibration: self.calibration)
            var summarized: Int?
            if let range = plan.summarize, let run, let summary {
                summarized = self.ledger.summarize(range, expecting: run, text: summary, calibration: self.calibration)
            }
            var parts: [String] = []
            if !plan.elide.isEmpty { parts.append("cleared \(plan.elide.count) old tool result\(plan.elide.count == 1 ? "" : "s")") }
            if summarized != nil, let run { parts.append("summarized \(run.count) earlier messages") }
            guard !parts.isEmpty else { return }
            let freed = cleared + (summarized ?? 0)
            let sentence = parts.joined(separator: " and ")
            coordinator.send(.noticeShown("\(sentence.prefix(1).uppercased() + sentence.dropFirst()) to make room (about \(freed) tokens). The full text stays visible here.", symbol: "scissors"))
            // Read the new prompt now so the next reply doesn't have to.
            guard !strained else { return }
            let warm = self.ledger.messages
            guard let stream = try? await inference.generate(
                messages: warm, tools: [], options: GenerationOptions(maxTokens: 1),
                priority: .background, pin: localID) else { return }
            do { for try await _ in stream {} } catch { return }
        }
    }

    /// What a rewrite done by a model on this Mac continues from: this conversation's prompt as the
    /// model has it (so its cached prefix stays warm), or just the system message before the first
    /// send or when the visible chat and the ledger disagree (a cleared chat).
    private func optimizerPrefix(promptCount: Int) -> [ChatMessage] {
        if !ledger.isEmpty, ledger.userTurns == promptCount { return ledger.messages }
        return [ChatMessage(role: .system, content: buildSystemPrompt())]
    }

    /// The full text of one user turn: task guidance (from the prompt library), framing, retrieved
    /// code, then the request. `processIntent` and the "what the model sees" inspector both call this,
    /// so what the inspector shows is what gets sent.
    private func composeUserTurn(_ text: String, intentOverride: PromptEngineer.Intent?)
        async -> (turn: String, intent: PromptEngineer.Intent, usedContext: Bool)
    {
        let ragContext = await retrieveContext(for: text)
        let intent = intentOverride ?? PromptEngineer.classify(text)
        let recipe = await promptLibrary.recipeText(for: intent.rawValue)
        let turn = PromptEngineer.augmentUserTurn(text, intent: intent, ragContext: ragContext, recipe: recipe)
        return (turn, intent, ragContext != nil)
    }

    /// Exactly what the next message would send, for the inspector.
    public struct PromptPreview: Sendable {
        public let system: String
        public let userTurn: String
        public let intent: String
        public let usedRetrievedCode: Bool
        /// Messages already in this conversation's prompt (they are sent again as the prefix).
        public let earlierMessages: Int
        public let estimatedTokens: Int
    }

    public func previewNextTurn(_ text: String, intent: PromptEngineer.Intent? = nil) async -> PromptPreview {
        let composed = await composeUserTurn(text, intentOverride: intent)
        let system = ledger.messages.first(where: { $0.role == .system })?.content ?? buildSystemPrompt()
        let earlier = max(0, ledger.messages.count - (ledger.isEmpty ? 0 : 1))
        let tokens = InferenceService.estimateTokens(ledger.messages + [ChatMessage(role: .user, content: composed.turn)])
            + (ledger.isEmpty ? PromptTokens.estimate(system) : 0)
        return PromptPreview(system: system, userTurn: composed.turn, intent: composed.intent.rawValue,
                             usedRetrievedCode: composed.usedContext, earlierMessages: earlier, estimatedTokens: tokens)
    }

    /// A line for the chat when the answer didn't come from the local model the way you'd expect.
    nonisolated static func noticeText(_ notice: RouteNotice, load: SystemLoad) -> String? {
        switch notice.kind {
        case .fellBack(let from, let to, let reason):
            let what = from.hasPrefix("local:") ? "The model on this Mac" : from
            return "\(what) couldn't answer (\(reason)), so this reply comes from \(to) in the cloud."
        case .using(let id):
            guard !id.hasPrefix("local:"), let why = load.explanation else { return nil }
            return "\(why), so this reply comes from \(id) in the cloud."
        }
    }

    private func executeTool(_ call: ToolCall, handlers: [AgentToolHandler]) async -> String {
        guard let handler = handlers.first(where: { $0.toolDefinition.name == call.name }) else {
            return "Unknown tool: \(call.name)"
        }
        do {
            let args = parseToolArguments(call.arguments)
            if let refusal = await toolGuard.refusal(for: handler, arguments: args, client: Self.chatIdentity, context: untrusted) {
                return refusal
            }
            let contents = toolGuard.filter(try await handler.execute(arguments: args), from: handler, context: untrusted)
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
        try? await registry.discover(localDirectory: url, remoteConfigs: [], credentials: credentials, gate: egress)
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
        try? await registry.discover(localDirectory: modelsDir, remoteConfigs: [], credentials: credentials, gate: egress)
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
        try ModelRegistry.saveRemoteConfig(config)
        try? await registry.discover(localDirectory: nil, remoteConfigs: [config], credentials: credentials, gate: egress)
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
            let chunks = results.map {
                RetrievalBudget.Chunk(fileName: URL(fileURLWithPath: $0.filePath).lastPathComponent,
                                      kind: $0.declarationKind, content: $0.content)
            }
            // Only as much as this turn has room for; the chunker has no size limit of its own.
            let room = RetrievalBudget.maxTokens(
                ceiling: (await inference.localContextLimit()).map { min($0, Self.contextTokenBudget) },
                currentPromptTokens: calibration.tokens(of: ledger.messages))
            return RetrievalBudget.render(chunks, maxTokens: room, calibration: calibration)
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
            case .toolCall, .error, .notice:
                break
            }
        }
        if !pendingAssistant.isEmpty {
            candidates.insert(ChatMessage(role: .assistant, content: pendingAssistant), at: 0)
        }

        return candidates
    }

    private func buildSystemPrompt() -> String {
        var lines = [Self.identityPrompt(persona: defaults.object(forKey: Self.personaKey) as? Bool ?? true,
                                         addressName: defaults.string(forKey: Self.addressNameKey),
                                         customPersonality: defaults.string(forKey: Self.personalityKey))]
        if let workspace = detectWorkspaceURL() {
            lines.append("Workspace root: \(workspace.path)")
        }
        if let swiftVersion = cachedSwiftVersion() {
            lines.append("Swift version: \(swiftVersion)")
        }
        if snapshotManager != nil {
            lines.append("Git snapshots are available. Prefer small, focused edits.")
        }
        lines.append(UntrustedContent.systemPromptRule)
        return lines.joined(separator: "\n")
    }

    static let personaKey = "kokoroPersonaEnabled"
    static let addressNameKey = "kokoroAddressName"
    static let personalityKey = "kokoroPersonality"
    /// Longest custom personality that is used (about 150 tokens). It rides along with every
    /// conversation and eats local context, so it is capped rather than trusted to be short.
    public nonisolated static let personalityLimit = 600

    /// Kokoro's default voice. This is the part the user can rewrite in Settings; the rules below
    /// it (substance, stack, no persona in code) always apply.
    public nonisolated static let defaultPersonality = """
        You are Kokoro, a calm, concise assistant that helps a developer write precise prompts.

        Voice: friendly and brief. No exclamation marks or flourishes; a short encouraging word is fine.
        """

    /// What never changes, whatever personality the user writes.
    nonisolated static let coreRules = """
        You work inside Kokoro, a macOS sidecar that helps developers write prompts for frontier AI models (Claude Code, Cursor, ChatGPT) and runs on a local model.

        Substance comes first: be correct, concise and safe. If unsure an API or flag exists, say so and check by reading the code or building; never invent one. Prefer small, focused edits.

        Stack: Swift 6, SwiftUI/AppKit, actors, MLX. Never suggest Python, Node, Docker or HTTP between app components; use the native in-process Swift equivalent.

        Whatever your voice, never use it in code, diffs, commit messages, tool arguments, file contents or the prompts you draft.
        """

    /// The user's personality text if they wrote one (trimmed, capped), else the default.
    public nonisolated static func effectivePersonality(_ custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultPersonality }
        return String(trimmed.prefix(personalityLimit))
    }

    /// Who the model is. Kept short and fixed for the session: the system message is built once
    /// so the local prefix cache stays valid.
    nonisolated static func identityPrompt(persona: Bool, addressName: String?, customPersonality: String? = nil) -> String {
        guard persona else {
            return "You are an assistant that helps a developer write precise prompts for frontier AI models. Be accurate and concise."
        }
        var text = effectivePersonality(customPersonality) + "\n\n" + coreRules
        if let name = addressName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            text += "\nAddress the user as \(name)."
        }
        return text
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

/// One build helper connection shared by every project, connected on first use.
actor SharedBuildRunner {
    private var runner: XPCBuildRunner?
    func get() async -> XPCBuildRunner {
        if let runner { return runner }
        let r = XPCBuildRunner()
        await r.connect()
        runner = r
        return r
    }
}
