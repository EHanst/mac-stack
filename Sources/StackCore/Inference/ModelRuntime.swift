import Foundation
import os

public enum ModelRuntimeState: Sendable, Equatable {
    case unloaded, loading, ready, busy
}

public actor ModelRuntime {

    public private(set) var state: ModelRuntimeState = .unloaded

    private let loader: @Sendable () async throws -> Void
    private let unloader: @Sendable () async -> Void
    private let idleTimeout: Duration
    private let logger = Logger(subsystem: "com.vibecockpit", category: "ModelRuntime")

    private var loadTask: Task<Void, Error>?
    private var idleTask: Task<Void, Never>?
    private var acquireCount: Int = 0

    public init(
        loader: @escaping @Sendable () async throws -> Void,
        unloader: @escaping @Sendable () async -> Void,
        idleTimeout: Duration = .seconds(300)
    ) {
        self.loader = loader
        self.unloader = unloader
        self.idleTimeout = idleTimeout
    }

    public func acquire() async throws {
        idleTask?.cancel()
        idleTask = nil
        acquireCount += 1

        switch state {
        case .unloaded:
            if let existing = loadTask {
                state = .loading
                try await existing.value
            } else {
                state = .loading
                let task = Task { [loader] in try await loader() }
                loadTask = task
                try await task.value
                loadTask = nil
            }
            state = .busy
        case .loading:
            try await loadTask?.value
            state = .busy
        case .ready, .busy:
            state = .busy
        }
    }

    public func release() {
        acquireCount = max(0, acquireCount - 1)
        if acquireCount == 0 {
            state = .ready
            scheduleIdleEviction()
        }
    }

    public func forceUnload() async {
        idleTask?.cancel()
        loadTask?.cancel()
        await unloader()
        state = .unloaded
        loadTask = nil
        idleTask = nil
    }

    private func scheduleIdleEviction() {
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.evict()
            } catch { /* cancelled */ }
        }
    }

    private func evict() async {
        guard state == .ready else { return }
        logger.info("Model idle timeout — unloading weights")
        await unloader()
        state = .unloaded
    }
}
