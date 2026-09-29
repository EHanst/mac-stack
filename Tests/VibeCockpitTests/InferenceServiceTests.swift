import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

private actor Probe {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var calls: [String] = []
    func enter(_ id: String) { active += 1; maxActive = max(maxActive, active); calls.append(id) }
    func leave() { active -= 1 }
}

private struct StubFailure: Error, LocalizedError { var errorDescription: String? { "stub failure" } }

private actor StubProvider: ModelProvider {
    enum Behavior: Sendable {
        case tokens([String])
        case failBeforeOutput
        case tokensThenFail([String])
        case slow(milliseconds: Int)
    }

    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities = [.textGeneration, .streaming]
    let behavior: Behavior
    let probe: Probe
    let contextLimit: Int?
    let health: ProviderHealth

    init(id: String, behavior: Behavior, probe: Probe, contextLimit: Int? = nil, health: ProviderHealth = .healthy) {
        self.id = id
        self.behavior = behavior
        self.probe = probe
        self.contextLimit = contextLimit
        self.health = health
    }

    func generate(messages: [Message], tools: [ToolDefinition],
                  options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let id = self.id, behavior = self.behavior, probe = self.probe
        return AsyncThrowingStream { c in
            let task = Task {
                await probe.enter(id)
                defer { Task { await probe.leave() } }
                switch behavior {
                case .tokens(let ts):
                    for t in ts { c.yield(.token(t)) }
                    c.yield(.finished(.stop)); c.finish()
                case .failBeforeOutput:
                    c.finish(throwing: StubFailure())
                case .tokensThenFail(let ts):
                    for t in ts { c.yield(.token(t)) }
                    c.finish(throwing: StubFailure())
                case .slow(let ms):
                    try? await Task.sleep(for: .milliseconds(ms))
                    c.yield(.token(id)); c.yield(.finished(.stop)); c.finish()
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
    func healthCheck() async -> ProviderHealth { health }
    func maxContextTokens() async -> Int? { contextLimit }
}

@Suite("InferenceService")
struct InferenceServiceTests {

    private let msgs = [Message(role: .user, content: "hi")]

    private func service(_ providers: [StubProvider], policy: RoutingPolicy = .localFirst,
                         notices: NoticeLog? = nil) async -> InferenceService {
        let registry = ModelRegistry()
        for p in providers { await registry.register(p) }
        let svc = InferenceService(registry: registry, policy: policy)
        if let notices { await svc.setNoticeHandler { n in Task { await notices.add(n) } } }
        return svc
    }

    private func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> String {
        var text = ""
        for try await e in stream { if case .token(let t) = e { text += t } }
        return text
    }

    actor NoticeLog {
        private(set) var items: [RouteNotice] = []
        func add(_ n: RouteNotice) { items.append(n) }
    }

    @Test("localFirst uses the local provider and never touches cloud")
    func prefersLocal() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "openai", behavior: .tokens(["cloud"]), probe: probe),
            StubProvider(id: "local:bonsai", behavior: .tokens(["local"]), probe: probe),
        ])
        let text = try await collect(try await svc.generate(messages: msgs, tools: []))
        #expect(text == "local")
        #expect(await probe.calls == ["local:bonsai"])
    }

    @Test("falls back to cloud when local fails before producing output, and reports it")
    func fallsBack() async throws {
        let probe = Probe(), log = NoticeLog()
        let svc = await service([
            StubProvider(id: "local:bonsai", behavior: .failBeforeOutput, probe: probe),
            StubProvider(id: "openai", behavior: .tokens(["cloud answer"]), probe: probe),
        ], notices: log)
        let text = try await collect(try await svc.generate(messages: msgs, tools: []))
        #expect(text == "cloud answer")
        try await Task.sleep(for: .milliseconds(30))
        let kinds = await log.items.map(\.kind)
        #expect(kinds.first == .using("local:bonsai"))
        #expect(kinds.contains { if case .fellBack(let from, let to, _) = $0 { from == "local:bonsai" && to == "openai" } else { false } })
    }

    @Test("does not fall back after output has started; the error is passed through")
    func noFallbackMidStream() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "local:bonsai", behavior: .tokensThenFail(["partial"]), probe: probe),
            StubProvider(id: "openai", behavior: .tokens(["cloud"]), probe: probe),
        ])
        var got = ""
        await #expect(throws: StubFailure.self) {
            for try await e in try await svc.generate(messages: msgs, tools: []) {
                if case .token(let t) = e { got += t }
            }
        }
        #expect(got == "partial")
        #expect(await probe.calls == ["local:bonsai"])
    }

    @Test("localOnly never uses cloud, even when local fails")
    func localOnlyStaysLocal() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "local:bonsai", behavior: .failBeforeOutput, probe: probe),
            StubProvider(id: "openai", behavior: .tokens(["cloud"]), probe: probe),
        ], policy: .localOnly)
        await #expect(throws: StubFailure.self) { _ = try await collect(try await svc.generate(messages: msgs, tools: [])) }
        #expect(await probe.calls == ["local:bonsai"])
    }

    @Test("localOnly with only cloud providers throws noProvider")
    func localOnlyNoLocal() async {
        let svc = await service([StubProvider(id: "openai", behavior: .tokens(["x"]), probe: Probe())], policy: .localOnly)
        await #expect(throws: InferenceError.self) { _ = try await svc.generate(messages: msgs, tools: []) }
    }

    @Test("an unavailable local provider is skipped without being called")
    func skipsUnavailable() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "local:bonsai", behavior: .tokens(["local"]), probe: probe, health: .unavailable("no memory")),
            StubProvider(id: "openai", behavior: .tokens(["cloud"]), probe: probe),
        ])
        #expect(try await collect(try await svc.generate(messages: msgs, tools: [])) == "cloud")
        #expect(await probe.calls == ["openai"])
    }

    @Test("cloudAllowed sends over-limit prompts to cloud; small ones stay local")
    func overContextGoesToCloud() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "local:bonsai", behavior: .tokens(["local"]), probe: probe, contextLimit: 10),
            StubProvider(id: "openai", behavior: .tokens(["cloud"]), probe: probe),
        ], policy: .cloudAllowed)
        let big = [Message(role: .user, content: String(repeating: "x", count: 500))]
        #expect(try await collect(try await svc.generate(messages: big, tools: [])) == "cloud")
        #expect(try await collect(try await svc.generate(messages: msgs, tools: [])) == "local")
    }

    @Test("local requests are serialised by the scheduler")
    func localSerialised() async throws {
        let probe = Probe()
        let svc = await service([StubProvider(id: "local:bonsai", behavior: .slow(milliseconds: 25), probe: probe)])
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<4 {
                g.addTask { _ = try await self.collect(try await svc.generate(messages: self.msgs, tools: [])) }
            }
            try await g.waitForAll()
        }
        #expect(await probe.maxActive == 1)
    }

    @Test("a slow local request holding the GPU slot does not block a cloud request on the same scheduler")
    func cloudNotBlockedByLocal() async throws {
        let probe = Probe()
        let registry = ModelRegistry()
        await registry.register(StubProvider(id: "local:bonsai", behavior: .slow(milliseconds: 400), probe: probe, contextLimit: 10))
        await registry.register(StubProvider(id: "openai", behavior: .tokens(["cloud"]), probe: probe))
        let shared = InferenceScheduler(maxConcurrent: 1)
        let localSvc = InferenceService(registry: registry, scheduler: shared, policy: .localOnly)
        let cloudSvc = InferenceService(registry: registry, scheduler: shared, policy: .cloudAllowed)

        let slow = Task { try await self.collect(try await localSvc.generate(messages: self.msgs, tools: [])) }
        for _ in 0..<100 where await shared.runningCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await shared.runningCount == 1)                    // local really is holding the slot

        let big = [Message(role: .user, content: String(repeating: "x", count: 500))]   // over local limit → cloud first
        let started = Date()
        let text = try await collect(try await cloudSvc.generate(messages: big, tools: []))
        #expect(text == "cloud")
        #expect(Date().timeIntervalSince(started) < 0.2)           // well under the local request's 400 ms
        #expect(await shared.runningCount == 1)                    // local still running
        _ = try await slow.value
    }
}
