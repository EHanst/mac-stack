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

private actor EmbedStub: ModelProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities = [.embedding]
    let fail: Bool
    let value: Float
    init(id: String, value: Float, fail: Bool = false) { self.id = id; self.value = value; self.fail = fail }
    func generate(messages: [Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: StubFailure()) }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        if fail { throw StubFailure() }
        return texts.map { _ in [value] }
    }
    func healthCheck() async -> ProviderHealth { .healthy }
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

    @Test("the local context limit ignores a local model that cannot serve right now")
    func contextLimitSkipsUnavailableLocal() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "local:big", behavior: .tokens(["x"]), probe: probe, contextLimit: 0, health: .unavailable("no memory")),
            StubProvider(id: "local:small", behavior: .tokens(["x"]), probe: probe, contextLimit: 40_000),
        ])
        #expect(await svc.localContextLimit() == 40_000)
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
        let text = try await collect(try await cloudSvc.generate(messages: big, tools: []))
        #expect(text == "cloud")
        // Cloud finished while local still holds the slot, so it never waited for it.
        // (A wall-clock bound here flaked on slow CI runners.)
        #expect(await shared.runningCount == 1)
        _ = try await slow.value
    }

    // MARK: Pinned models, listing, embeddings (used by the HTTP API)

    @Test("a pinned model is used even when routing would prefer another; no fallback if it fails")
    func pinned() async throws {
        let probe = Probe()
        let svc = await service([
            StubProvider(id: "local:bonsai", behavior: .tokens(["local"]), probe: probe),
            StubProvider(id: "openai", behavior: .failBeforeOutput, probe: probe),
        ])
        await #expect(throws: StubFailure.self) {
            _ = try await self.collect(try await svc.generate(messages: self.msgs, tools: [], pin: "openai"))
        }
        #expect(await probe.calls == ["openai"])                       // asked for openai ⇒ never silently answered by local
    }

    @Test("an unknown model id is an error, not a silent reroute")
    func unknownModel() async {
        let svc = await service([StubProvider(id: "local:bonsai", behavior: .tokens(["x"]), probe: Probe())])
        await #expect(throws: InferenceError.unknownModel("gpt-9")) { _ = try await svc.generate(messages: self.msgs, tools: [], pin: "gpt-9") }
    }

    @Test("Only-on-this-Mac refuses a pinned cloud model")
    func pinnedCloudRefusedByPolicy() async {
        let svc = await service([StubProvider(id: "openai", behavior: .tokens(["x"]), probe: Probe())], policy: .localOnly)
        await #expect(throws: InferenceError.notAllowedByPolicy(model: "openai", policy: .localOnly)) {
            _ = try await svc.generate(messages: self.msgs, tools: [], pin: "openai")
        }
    }

    @Test("pinning an embedding-only model for chat is an unknown model")
    func pinWrongCapability() async {
        let registry = ModelRegistry()
        await registry.register(EmbedStub(id: "local:embed", value: 1))
        let svc = InferenceService(registry: registry)
        await #expect(throws: InferenceError.unknownModel("local:embed")) { _ = try await svc.generate(messages: self.msgs, tools: [], pin: "local:embed") }
    }

    @Test("model listing shows local first, then cloud, with health and capabilities")
    func listing() async throws {
        let registry = ModelRegistry()
        await registry.register(StubProvider(id: "openai", behavior: .tokens(["x"]), probe: Probe()))
        await registry.register(StubProvider(id: "local:bonsai", behavior: .tokens(["x"]), probe: Probe(), health: .degraded("loading")))
        await registry.register(EmbedStub(id: "local:embed", value: 1))
        let list = await InferenceService(registry: registry).availableModels()
        #expect(list.map(\.id) == ["local:bonsai", "local:embed", "openai"])
        #expect(list[0].isLocal && list[0].health == .degraded("loading") && !list[2].isLocal)
        #expect(list[1].capabilities == [.embedding])
    }

    @Test("embeddings use the local embedder first and fall back to cloud when it fails")
    func embeddings() async throws {
        let registry = ModelRegistry()
        await registry.register(EmbedStub(id: "local:embed", value: 1))
        await registry.register(EmbedStub(id: "cloud-embed", value: 2))
        let ok = try await InferenceService(registry: registry).embed(["a", "b"])
        #expect(ok.provider == "local:embed" && ok.vectors == [[1], [1]])

        let registry2 = ModelRegistry()
        await registry2.register(EmbedStub(id: "local:embed", value: 1, fail: true))
        await registry2.register(EmbedStub(id: "cloud-embed", value: 2))
        let fallback = try await InferenceService(registry: registry2).embed(["a"])
        #expect(fallback.provider == "cloud-embed")
        // Only on this Mac: the local failure is reported as it is; the cloud embedder is never tried.
        await #expect(throws: StubFailure.self) { _ = try await InferenceService(registry: registry2, policy: .localOnly).embed(["a"]) }
    }

    @Test("a pinned embedding model is used as asked")
    func pinnedEmbedding() async throws {
        let registry = ModelRegistry()
        await registry.register(EmbedStub(id: "local:embed", value: 1))
        await registry.register(EmbedStub(id: "cloud-embed", value: 2))
        let r = try await InferenceService(registry: registry).embed(["a"], pin: "cloud-embed")
        #expect(r.provider == "cloud-embed")
    }
}

@Suite("Request log")
struct RequestLogRecordingTests {
    private let msgs = [Message(role: .user, content: "a secret prompt")]

    private func run(_ providers: [StubProvider], priority: InferenceScheduler.Priority = .interactive) async throws -> [RequestRecord] {
        let registry = ModelRegistry()
        for p in providers { await registry.register(p) }
        let log = RequestLog()
        let svc = InferenceService(registry: registry, requestLog: log)
        let stream = try await svc.generate(messages: msgs, tools: [], priority: priority)
        do { for try await _ in stream {} } catch {}
        try await Task.sleep(for: .milliseconds(30))
        return await log.recent
    }

    @Test("a normal reply is logged with source, provider, timing and no text")
    func normal() async throws {
        let probe = Probe()
        let recs = try await run([StubProvider(id: "local:bonsai", behavior: .tokens(["hello ", "there"]), probe: probe)], priority: .api)
        let r = try #require(recs.first)
        #expect(recs.count == 1 && r.source == "api" && r.provider == "local:bonsai" && r.isLocal)
        #expect(r.outcome == .completed && r.timeToFirstToken != nil && r.totalTime >= r.timeToFirstToken!)
        #expect(r.promptTokens > 0 && r.completionTokens > 0)
        let json = String(decoding: try JSONEncoder().encode(recs), as: UTF8.self)
        #expect(!json.contains("secret") && !json.contains("hello"))
    }

    @Test("a fallback logs the failed attempt and the answer that followed")
    func fallback() async throws {
        let probe = Probe()
        let recs = try await run([
            StubProvider(id: "local:bonsai", behavior: .failBeforeOutput, probe: probe),
            StubProvider(id: "openai", behavior: .tokens(["ok"]), probe: probe),
        ])
        #expect(recs.map(\.outcome) == [.failed, .completed])
        #expect(recs[0].error == "stub failure")
        #expect(recs[1].fellBackFrom == "local:bonsai" && !recs[1].isLocal)
    }
}

@Suite("Why was it slow")
struct SlowReasonTests {
    private func rec(_ t: Double, prompt: Int = 100, ttft: Double? = 0.5, total: Double = 3, completion: Int = 60,
                     local: Bool = true, source: String = "app", memory: String = "normal", thermal: String = "nominal",
                     low: Bool = false, outcome: RequestRecord.Outcome = .completed, from: String? = nil) -> RequestRecord {
        RequestRecord(date: Date(timeIntervalSince1970: t), source: source, provider: local ? "local:bonsai" : "openai",
                      isLocal: local, fellBackFrom: from, promptTokens: prompt, completionTokens: completion,
                      timeToFirstToken: ttft, totalTime: total, outcome: outcome,
                      memory: memory, thermal: thermal, lowPowerMode: low)
    }

    @Test("a long prompt is blamed for a slow first word")
    func longPrompt() {
        let text = SlowReason.explain(rec(100, prompt: 20000, ttft: 12), earlier: []).joined(separator: " ")
        #expect(text.contains("conversation is long") && text.contains("12.0 s"))
    }

    @Test("a short prompt with a slow first word points at loading or another request")
    func shortPrompt() {
        #expect(SlowReason.explain(rec(100, prompt: 50, ttft: 8), earlier: []).joined().contains("short prompt"))
    }

    @Test("another request still running is named")
    func overlap() {
        let earlier = [rec(90, total: 30, source: "api")]   // ran 90…120
        let text = SlowReason.explain(rec(100), earlier: earlier).joined()
        #expect(text.contains("from api") && text.contains("one at a time"))
        #expect(!SlowReason.explain(rec(200), earlier: earlier).joined().contains("one at a time"))
    }

    @Test("strained system, fallback, cloud and failure are each reported")
    func others() {
        #expect(SlowReason.explain(rec(1, memory: "critical", thermal: "serious", low: true), earlier: []).joined()
            .contains("very short on memory and running hot and in Low Power Mode"))
        #expect(SlowReason.explain(rec(1, local: false, from: "local:bonsai"), earlier: []).joined().contains("couldn't answer"))
        #expect(SlowReason.explain(rec(1, local: false), earlier: []).joined().contains("in the cloud"))
        #expect(SlowReason.explain(rec(1, outcome: .failed), earlier: []).joined().hasPrefix("It failed"))
    }

    @Test("slower than the usual speed needs enough history, then says so")
    func slowerThanUsual() {
        let fast = (0..<4).map { rec(Double($0) * 100, ttft: 0.5, total: 6.5, completion: 60) }   // 10 tok/s
        let slow = rec(1000, ttft: 0.5, total: 20.5, completion: 60)                                // 3 tok/s
        #expect(SlowReason.explain(slow, earlier: fast).joined().contains("slower than your usual"))
        #expect(!SlowReason.explain(slow, earlier: Array(fast.prefix(2))).joined().contains("slower than your usual"))
    }

    @Test("nothing wrong still gives a line with the numbers")
    func fine() {
        let text = SlowReason.explain(rec(1, ttft: 0.5, total: 6.5, completion: 60), earlier: []).joined()
        #expect(text.hasPrefix("Nothing unusual found") && text.contains("10.0 words per second"))
    }

    @Test("the log keeps the newest records and survives a restart")
    func logPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = RequestLog(capacity: 3, fileURL: url)
        for i in 0..<5 { await log.record(rec(Double(i))) }
        #expect(await log.recent.map(\.date.timeIntervalSince1970) == [2, 3, 4])
        #expect(await RequestLog(capacity: 3, fileURL: url).recent.count == 3)
    }
}

@Suite("Support bundle")
struct SupportBundleTests {
    private func input(crash: [SupportBundleInput.CrashReport] = []) -> SupportBundleInput {
        let rec = RequestRecord(date: Date(), source: "app", provider: "local:bonsai", isLocal: true,
                                promptTokens: 10, completionTokens: 5, timeToFirstToken: 0.4, totalTime: 2, outcome: .completed)
        let egress = EgressEntry(id: UUID(), date: Date(), purpose: .cloudInference, host: "api.openai.com",
                                 provider: "openai", blocked: false, reason: nil, count: 2)
        return SupportBundleInput(
            appVersion: "1.0", build: "7", osVersion: "26.0", chip: "Apple M3 Pro", memoryGB: 18,
            routingPolicy: "localFirst", systemLoad: SystemLoad(memory: .warning, thermal: .fair, lowPowerMode: true),
            installedModels: ["local:bonsai"], providers: [.init(id: "openai", isLocal: false)],
            requests: [rec], egress: [egress], tokensThisMonth: 1234, monthlyTokenCap: 5000,
            externalServers: [.init(name: "GitHub", status: "Running")], projectCount: 2, crashReports: crash)
    }

    @Test("contains the facts support needs")
    func content() throws {
        let obj = try #require(JSONSerialization.jsonObject(with: try SupportBundle.make(input())) as? [String: Any])
        #expect((obj["system"] as? [String: String])?["chip"] == "Apple M3 Pro")
        #expect((obj["load"] as? [String: String])?["memory"] == "warning")
        #expect((obj["requests"] as? [[String: Any]])?.count == 1)
        let egress = try #require((obj["egress"] as? [[String: Any]])?.first)
        #expect(egress["host"] as? String == "api.openai.com" && egress["purpose"] as? String == "cloudInference")
        #expect(obj["projectCount"] as? Int == 2)
    }

    @Test("only whitelisted fields exist, so no text, keys or paths can appear")
    func noSensitiveFields() throws {
        let obj = try #require(JSONSerialization.jsonObject(with: try SupportBundle.make(input())) as? [String: Any])
        #expect(Set(obj.keys) == ["generatedAt", "note", "app", "system", "load", "routingPolicy", "installedModels",
                                  "providers", "cloudUse", "requests", "egress", "externalServers", "projectCount", "crashReports"])
        let req = try #require((obj["requests"] as? [[String: Any]])?.first)
        #expect(Set(req.keys).isDisjoint(with: ["content", "prompt", "text", "messages", "answer", "response"]))
        let e = try #require((obj["egress"] as? [[String: Any]])?.first)
        #expect(Set(e.keys) == ["date", "purpose", "host", "provider", "blocked", "count"])
    }

    @Test("crash reports are capped in number and size")
    func crashCaps() throws {
        let many = (0..<9).map { SupportBundleInput.CrashReport(file: "r\($0).json", json: String(repeating: "x", count: 300_000)) }
        let obj = try #require(JSONSerialization.jsonObject(with: try SupportBundle.make(input(crash: many))) as? [String: Any])
        let reports = try #require(obj["crashReports"] as? [[String: String]])
        #expect(reports.count == SupportBundle.maxCrashReports)
        #expect(reports[0]["json"]?.count == SupportBundle.maxCrashReportCharacters)
        #expect(reports.last?["file"] == "r8.json")
    }
}
