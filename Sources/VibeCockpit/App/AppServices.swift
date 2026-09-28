import Foundation
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
    private var startupComplete = false
    private let logger = Logger(subsystem: "com.vibecockpit", category: "AppServices")

    public init() {}

    // MARK: - Startup

    public func startup(coordinator: AppCoordinator, workspaceURL: URL? = nil) async {
        guard !startupComplete else { return }
        startupComplete = true

        if let url = workspaceURL ?? detectWorkspaceURL() {
            snapshotManager = GitSnapshotManager(workspaceURL: url)
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
    }

    // MARK: - Inference

    public func processIntent(_ text: String, coordinator: AppCoordinator) async {
        guard let provider = await registry.preferredProvider(for: .textGeneration) else {
            coordinator.send(.tokenReceived("\n\n⚠️ No model provider configured. Complete onboarding first."))
            coordinator.send(.generationFinished)
            return
        }

        coordinator.send(.generationStarted)
        let messages = buildMessages(coordinator.state)

        do {
            let stream = await provider.generate(messages: messages, tools: [], options: GenerationOptions())
            for try await event in stream {
                switch event {
                case .token(let t):
                    coordinator.send(.tokenReceived(t))
                case .toolCall(let call):
                    coordinator.send(.toolCallMade(call.name, call.arguments))
                case .finished:
                    break
                }
            }
        } catch {
            coordinator.send(.tokenReceived("\n\n⚠️ Generation error: \(error.localizedDescription)"))
        }

        coordinator.send(.generationFinished)
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
            coordinator.send(.tokenReceived("\n\n⚠️ Restore failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Private helpers

    private func buildMessages(_ state: AppState) -> [Message] {
        var msgs: [Message] = [
            Message(role: .system, content: "You are VibeCockpit, an AI coding assistant. Help the user build and modify macOS Swift applications.")
        ]
        var pendingAssistant = ""
        for event in state.intentHistory {
            switch event.kind {
            case .userPrompt:
                if !pendingAssistant.isEmpty {
                    msgs.append(Message(role: .assistant, content: pendingAssistant))
                    pendingAssistant = ""
                }
                msgs.append(Message(role: .user, content: event.content))
            case .assistantToken:
                pendingAssistant += event.content
            case .toolCall, .error:
                break
            }
        }
        if !pendingAssistant.isEmpty {
            msgs.append(Message(role: .assistant, content: pendingAssistant))
        }
        return msgs
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
