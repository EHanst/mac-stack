import Testing
import Foundation
@testable import VibeCockpitCore

private actor Log {
    private(set) var events: [String] = []
    private(set) var active = 0
    private(set) var maxActive = 0
    func add(_ e: String) { events.append(e) }
    func enter() { active += 1; maxActive = max(maxActive, active) }
    func leave() { active -= 1 }
}

@Suite("InferenceScheduler")
struct InferenceSchedulerTests {

    /// Wait until `count` jobs are queued (bounded so a bug fails instead of hanging).
    private func waitForQueued(_ s: InferenceScheduler, _ count: Int) async throws {
        for _ in 0..<500 {
            if await s.queuedCount >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(count) queued jobs")
    }

    @Test("never exceeds maxConcurrent")
    func serialised() async throws {
        let s = InferenceScheduler(maxConcurrent: 1)
        let log = Log()
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<6 {
                g.addTask {
                    try await s.run(priority: .api) {
                        await log.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await log.leave()
                    }
                }
            }
            try await g.waitForAll()
        }
        #expect(await log.maxActive == 1)
    }

    @Test("higher priority jumps the queue; equal priorities stay FIFO")
    func priorityOrdering() async throws {
        let s = InferenceScheduler(maxConcurrent: 1)
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()

        // Occupy the slot.
        let holder = Task {
            try await s.run(priority: .api) {
                for await _ in gate.stream { break }
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        var tasks: [Task<Void, Error>] = []
        for (name, p) in [("bg", InferenceScheduler.Priority.background),
                          ("api1", .api), ("api2", .api), ("ui", .interactive)] {
            tasks.append(Task { try await s.run(priority: p) { await log.add(name) } })
            try await waitForQueued(s, tasks.count)
        }
        gate.continuation.yield()
        try await holder.value
        for t in tasks { try await t.value }
        #expect(await log.events == ["ui", "api1", "api2", "bg"])
    }

    @Test("cancelling a queued job removes it without running it")
    func cancelQueued() async throws {
        let s = InferenceScheduler(maxConcurrent: 1)
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        let holder = Task { try await s.run(priority: .api) { for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(20))

        let queued = Task { try await s.run(priority: .api) { await log.add("ran") } }
        try await waitForQueued(s, 1)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await s.queuedCount == 0)

        gate.continuation.yield()
        try await holder.value
        #expect(await log.events.isEmpty)
        #expect(await s.runningCount == 0)
    }

    @Test("a job that throws still frees its slot")
    func errorReleases() async throws {
        struct Boom: Error {}
        let s = InferenceScheduler(maxConcurrent: 1)
        await #expect(throws: Boom.self) { try await s.run(priority: .api) { throw Boom() } }
        #expect(await s.runningCount == 0)
        let v = try await s.run(priority: .api) { 42 }
        #expect(v == 42)
    }

    @Test("stream holds the slot until finished, then releases")
    func streamHoldsSlot() async throws {
        let s = InferenceScheduler(maxConcurrent: 1)
        let out = s.stream(priority: .api) {
            AsyncThrowingStream { c in
                Task {
                    for i in 0..<3 { c.yield(i); try? await Task.sleep(for: .milliseconds(5)) }
                    c.finish()
                }
            }
        }
        var seen: [Int] = []
        for try await v in out { seen.append(v); #expect(await s.runningCount == 1) }
        #expect(seen == [0, 1, 2])
        for _ in 0..<200 where await s.runningCount != 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await s.runningCount == 0)
    }

    @Test("abandoning a stream cancels the producer and frees the slot")
    func streamCancel() async throws {
        let s = InferenceScheduler(maxConcurrent: 1)
        let terminated = Log()
        let out = s.stream(priority: .api) {
            AsyncThrowingStream<Int, Error> { c in
                c.onTermination = { _ in Task { await terminated.add("terminated") } }
                c.yield(1)
            }
        }
        // Cancelling the consuming task (client disconnect) must reach the producer.
        let got = Log()
        let consumer = Task { for try await _ in out { await got.add("v") } }
        for _ in 0..<200 where await got.events.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        consumer.cancel()
        _ = try? await consumer.value
        for _ in 0..<200 where await s.runningCount != 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await s.runningCount == 0)
        #expect(await terminated.events == ["terminated"])
    }
}
