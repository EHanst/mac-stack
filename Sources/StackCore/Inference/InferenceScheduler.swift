import Foundation

/// Serialises access to the GPU. Every client (UI, API, MCP, indexing) submits work here;
/// higher priorities run first, ties run FIFO, and cancelling the caller frees its slot
/// whether it is still queued or already running.
public actor InferenceScheduler {

    public enum Priority: Int, Sendable, Comparable {
        case background = 0   // indexing, warm-up
        case api = 1          // external clients
        case interactive = 2  // the app's own UI

        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }

    private struct Waiter {
        let id: UInt64
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrent: Int
    private let maxQueued: Int
    private var running = 0
    private var waiters: [Waiter] = []          // insertion order == FIFO
    private var nextID: UInt64 = 0
    private var cancelledEarly: Set<UInt64> = []

    public init(maxConcurrent: Int = 1, maxQueued: Int = 128) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxQueued = max(1, maxQueued)
    }

    public var queuedCount: Int { waiters.count }
    public var runningCount: Int { running }

    // MARK: - Run a single operation

    public func run<T: Sendable>(
        priority: Priority,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority: priority)
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    // MARK: - Run a stream (slot is held until the stream ends or the consumer goes away)

    public nonisolated func stream<Element: Sendable>(
        priority: Priority,
        _ make: @escaping @Sendable () async -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.acquire(priority: priority)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                do {
                    let inner = await make()
                    for try await element in inner {
                        continuation.yield(element)
                    }
                    await self.release()
                    continuation.finish()
                } catch {
                    await self.release()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Slot management

    func acquire(priority: Priority) async throws {
        try Task.checkCancellation()
        if running < maxConcurrent, waiters.isEmpty {
            running += 1
            return
        }
        guard waiters.count < maxQueued else {
            throw CancellationError()
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if cancelledEarly.remove(id) != nil {
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: cont))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        running = max(0, running - 1)
        guard running < maxConcurrent, !waiters.isEmpty else { return }
        // Highest priority wins; `firstIndex` keeps FIFO order among equals.
        let top = waiters.map(\.priority).max()!
        let index = waiters.firstIndex { $0.priority == top }!
        let waiter = waiters.remove(at: index)
        running += 1
        waiter.continuation.resume()
    }

    private func cancelWaiter(_ id: UInt64) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledEarly.insert(id)   // cancellation raced ahead of enqueue
        }
    }
}
