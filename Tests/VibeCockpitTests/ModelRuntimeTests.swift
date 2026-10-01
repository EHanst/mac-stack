import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("ModelRuntime")
struct ModelRuntimeTests {

    @Test("loadModel called exactly once under concurrent acquire calls")
    func deduplicatedLoad() async throws {
        let counter = LoadCounter()
        let runtime = ModelRuntime(
            loader: { await counter.increment(); try await Task.sleep(for: .milliseconds(20)) },
            unloader: { },
            idleTimeout: .seconds(60)
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try await runtime.acquire() }
            }
            try await group.waitForAll()
        }
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("state transitions: unloaded -> busy -> ready")
    func stateTransitions() async throws {
        let runtime = ModelRuntime(
            loader: { try await Task.sleep(for: .milliseconds(10)) },
            unloader: { },
            idleTimeout: .seconds(60)
        )
        let s0 = await runtime.state
        #expect(s0 == .unloaded)
        try await runtime.acquire()
        let s1 = await runtime.state
        #expect(s1 == .busy)
        await runtime.release()
        let s2 = await runtime.state
        #expect(s2 == .ready)
    }

    @Test("idle eviction unloads after timeout")
    func idleEviction() async throws {
        let flag = UnloadFlag()
        let runtime = ModelRuntime(
            loader: { },
            unloader: { await flag.set() },
            idleTimeout: .milliseconds(80)
        )
        try await runtime.acquire()
        await runtime.release()
        // Wait for the eviction rather than guessing a delay: a loaded CI runner can be slow.
        let deadline = ContinuousClock.now + .seconds(10)
        while await runtime.state != .unloaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let s = await runtime.state
        #expect(s == .unloaded)
        let didUnload = await flag.value
        #expect(didUnload == true)
    }
}

private actor LoadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor UnloadFlag {
    private(set) var value = false
    func set() { value = true }
}
