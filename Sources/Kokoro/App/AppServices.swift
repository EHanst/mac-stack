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
    /// Project folders the user added; each has its own index, git and boundary.
    public let workspaces: WorkspaceManager
    /// Saved prompts.
    public let promptLibrary: PromptLibrary
    /// Save/insert/improve prompts from the chat box.
    public let promptStudio: PromptStudioModel
    public let sidecar: BriefSidecarModel
    public let feedback: BriefFeedbackModel
    public let improve: BriefImproveModel
    let workspaceSearch: WorkspaceSearch
    public let briefs = BriefWorkbenchModel(store: BriefStore())
    /// Prompts committed inside project folders (`.vibe/prompts`); usable only after the user approves each.
    public let projectPrompts: WorkspacePromptStore
    public let requestLog = RequestLog(fileURL: RequestLog.defaultURL())
    public let diagnostics: DiagnosticsModel
    public let workspacesModel: WorkspacesModel
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppServices")
    private var reindexTask: Task<Void, Never>?

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
        Task { await workspaces.setRemoveHandler { id in Task { await workspaceSearch.unregister(id: id) } } }
        let projectPrompts = WorkspacePromptStore(roots: { await workspaces.list.map { ($0.record.name, $0.record.url) } })
        self.projectPrompts = projectPrompts
        self.promptStudio = PromptStudioModel(
            library: promptLibrary, optimizer: PromptOptimizer(inference: inference),
            plannedModel: { await inference.plannedModel() },
            listModels: { await inference.availableModels() },
            projectPrompts: projectPrompts,
            defaults: defaults)
        let studio = self.promptStudio
        let briefSidecar = BriefSidecar { messages in
            // Room for the reply too; a request the local model can't hold fails with a sentence, not a stack.
            if let limit = await inference.localContextLimit(),
               InferenceService.estimateTokens(messages) + BriefSidecar.generationOptions.maxTokens > limit {
                throw SidecarError.tooLong
            }
            let pin = await MainActor.run { studio.optimizerPin }
            let stream = try await inference.generate(
                messages: messages, tools: [], options: BriefSidecar.generationOptions,
                priority: .interactive, pin: pin)
            var out = ""
            for try await event in stream {
                if case .token(let t) = event { out += t }
            }
            return out
        }
        self.sidecar = BriefSidecarModel(sidecar: briefSidecar)
        self.feedback = BriefFeedbackModel(sidecar: briefSidecar, workbench: self.briefs)
        self.improve = BriefImproveModel(sidecar: briefSidecar, workbench: self.briefs)
        let briefModel = self.briefs
        let requestLog = self.requestLog, governor = self.governor
        self.diagnostics = DiagnosticsModel(log: requestLog) {
            try await AppServices.makeSupportBundle(
                registry: registry, egress: gate, governor: governor, inference: inference,
                workspaces: workspaces, requestLog: requestLog)
        }
        self.workspacesModel = WorkspacesModel(manager: workspaces)
        let toolGate = ToolGate(memory: memory, approver: approvals)
        let host = MCPToolHost(inference: inference, gate: toolGate)
        self.mcpHost = host
        Task {
            await host.setProjectTools { await workspaces.tools() }
            await host.setWorkspaceOpener { try await workspaces.add($0) }
            // Other apps see your own prompts plus project prompts you approved; nothing else.
            await host.setBriefProvider { await briefModel.allBriefs() }
            await host.setPromptProvider { await promptLibrary.userPrompts() + projectPrompts.approvedPrompts() }
        }
        self.sharing = APISharingModel(inference: inference, defaults: defaults, mcp: MCPHTTPSessions(host: host))
    }

    private static let policyKey = DefaultsKey.routingPolicy

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
        // What a rewrite on the local model continues from: the system message, so its cached prefix stays warm.
        promptStudio.conversationPrefix = { [weak self] in
            guard let self else { return [] }
            return [Message(role: .system, content: self.buildSystemPrompt())]
        }
        await promptStudio.reload()
        briefs.contextSource = BriefContextSource(
            roots: { [workspaces] in await workspaces.list.map(\.record.url) },
            search: { [workspaceSearch] query in try await workspaceSearch.searchOrThrow(query, limit: 8) },
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
                    reindexTask?.cancel()
                    reindexTask = Task.detached(priority: .background) { [logger] in
                        do { try await pipeline.reindexWorkspace(workspaceURL) }
                        catch is CancellationError {}
                        catch { logger.error("Workspace reindex failed: \(error.localizedDescription, privacy: .public)") }
                    }
                    await pipeline.watch(workspaceURL)
                }
            } catch {
                logger.error("IndexingPipeline open failed: \(error.localizedDescription, privacy: .public)")
            }
        }


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
        await registry.choosePreferredLocal(ramBytes: ProcessInfo.processInfo.physicalMemory)
        // Only the preferred chat model: loading every installed one at once would not fit on small Macs.
        let preferredID = await registry.preferredLocalID
        let localProviders = await registry.allProviders(with: .textGeneration)
            .filter { $0.id.hasPrefix("local:") && (preferredID == nil || $0.id == preferredID) }
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
        workspaces: WorkspaceManager, requestLog: RequestLog
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
            projectCount: await workspaces.list.count,
            crashReports: reports)
        return try SupportBundle.make(input)
    }

    /// Builds one project's tools: its own git snapshots, its own search index, and a boundary
    /// that keeps file access and commands inside its folder.
    nonisolated static func openWorkspace(
        _ record: WorkspaceRecord, registry: ModelRegistry, runner: BuildRunner, search: WorkspaceSearch
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
        await registry.choosePreferredLocal(ramBytes: ProcessInfo.processInfo.physicalMemory)
        let preferredID = await registry.preferredLocalID
        let local = await registry.allProviders(with: .textGeneration)
            .filter { preferredID == nil || $0.id == preferredID }
            .compactMap { $0 as? LocalMLXProvider }
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
        let envKey = "KOKORO_\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_TOKEN"
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

    // MARK: - Private helpers

    private func buildSystemPrompt() -> String {
        Self.systemPrompt(workspaceRoot: detectWorkspaceURL()?.path)
    }

    /// Reference and facts first, the instructions last (principle 5). Pure and fixed per session, so the
    /// system message is identical every turn and the local prefix cache stays valid.
    nonisolated static func systemPrompt(workspaceRoot: String?) -> String {
        var parts = ["Principles for the prompts you write and review:\n" + PromptPrinciples.rules]
        if let workspaceRoot { parts.append("Workspace root: \(workspaceRoot)") }
        parts.append(instructions)
        return parts.joined(separator: "\n\n")
    }

    /// The task, its done-criteria, and the constraints. Each rule is stated once.
    public nonisolated static let instructions = """
        Goal: inside Kokoro, a macOS sidecar running on a local model, help a developer write precise prompts for frontier AI models. A good reply is one the developer can use as written.
        \(UntrustedContent.systemPromptRule)
        """

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

/// One build runner shared by every project, created on first use.
actor SharedBuildRunner {
    private var runner: BuildRunner?
    func get() async -> BuildRunner {
        if let runner { return runner }
        let r = BuildRunner()
        runner = r
        return r
    }
}
