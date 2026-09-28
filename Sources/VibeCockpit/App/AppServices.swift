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
    private let registry = ModelRegistry()
    private var snapshotManager: GitSnapshotManager?
    private var indexingPipeline: IndexingPipeline?
    private var mcpService: MCPService?
    private var buildRunner: XPCBuildRunner?
    private var startupComplete = false
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppServices")

    public init() {}

    // MARK: - Startup

    public func startup(coordinator: AppCoordinator, workspaceURL: URL? = nil) async {
        guard !startupComplete else { return }
        startupComplete = true

        if let url = workspaceURL ?? detectWorkspaceURL() {
            let mgr = GitSnapshotManager(workspaceURL: url)
            try? mgr.open()
            snapshotManager = mgr
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

        // Start embedded MCP server if we have a workspace
        if let workspaceURL = workspaceURL ?? detectWorkspaceURL(),
           let pipeline = indexingPipeline,
           let gitMgr = snapshotManager {
            let runner = XPCBuildRunner()
            runner.connect()
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
            } catch {
                logger.error("MCPService failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func stopMCPService() async {
        await mcpService?.stop()
        mcpService = nil
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

        let agentTools: [AgentToolHandler] = [FileReaderTool(), FileWriterTool()]
        let toolDefs = agentTools.map { h in
            ToolDefinition(name: h.toolDefinition.name, description: h.toolDefinition.description ?? "")
        }

        do {
            var continueLoop = true
            var isFirstTurn = true
            while continueLoop {
                let raw = buildMessages(coordinator.state, ragContext: isFirstTurn ? ragContext : nil)
                let messages = isFirstTurn ? PromptEngineer.engineer(messages: raw, intent: intent) : raw
                isFirstTurn = false
                let stream = await provider.generate(messages: messages, tools: toolDefs, options: GenerationOptions())
                var pendingToolCalls: [ToolCall] = []
                for try await event in stream {
                    switch event {
                    case .token(let t):
                        coordinator.send(.tokenReceived(t))
                    case .toolCall(let call):
                        coordinator.send(.toolCallMade(call.name, call.arguments, call.id))
                        pendingToolCalls.append(call)
                    case .finished:
                        break
                    }
                }
                if pendingToolCalls.isEmpty {
                    continueLoop = false
                } else {
                    for call in pendingToolCalls {
                        let result = await executeTool(call, handlers: agentTools)
                        coordinator.send(.toolResultReceived(call.id, result))
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
                if case .text(let t) = item { return t } else { return nil }
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

    private func buildMessages(_ state: AppState, ragContext: String? = nil) -> [Message] {
        let systemContent = buildSystemPrompt()
        let system = Message(role: .system, content: systemContent)

        // Assemble candidate messages from history, newest-first for budget trimming
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

        // Inject RAG context into the last user message
        if let rag = ragContext,
           let lastUserIdx = candidates.indices.reversed().first(where: { candidates[$0].role == .user }) {
            let original = candidates[lastUserIdx]
            candidates[lastUserIdx] = Message(
                role: .user,
                content: "\(rag)\n\nUser request: \(original.content)"
            )
        }

        // Budget: ~80% of maxTokens, approximated as chars/4
        let budget = (GenerationOptions().maxTokens * 4 * 4) / 5  // chars budget
        var usedChars = systemContent.count
        var kept: [Message] = []
        for msg in candidates.reversed() {
            usedChars += msg.content.count
            if usedChars > budget && !kept.isEmpty { break }
            kept.insert(msg, at: 0)
        }

        return [system] + kept
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
