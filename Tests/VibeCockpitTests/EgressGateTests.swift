import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
@testable import StackCore
@testable import StackMCP
@testable import StackHTTP

private final class MemEgressStore: EgressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = EgressState()
    func load() -> EgressState { lock.withLock { state } }
    func save(_ s: EgressState) { lock.withLock { state = s } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_790_000_000)   // Sep 2026
    var now: Date { lock.withLock { t } }
    func advance(days: Double) { lock.withLock { t = t.addingTimeInterval(days * 86_400) } }
}

private let cloud = URL(string: "https://api.openai.com/v1/chat/completions")!

@Suite("EgressGate")
struct EgressGateTests {

    @Test("Only on this Mac blocks cloud requests, and records the refusal")
    func localOnly() async {
        let gate = EgressGate(policy: .localOnly, store: MemEgressStore())
        await #expect(throws: EgressError.blockedByPrivacy(host: "api.openai.com")) {
            try await gate.authorize(.cloudInference, url: cloud)
        }
        let entries = await gate.entries
        #expect(entries.count == 1 && entries.allSatisfy { $0.blocked })
        #expect(await gate.cloudAllowed() != nil)
    }

    @Test("model downloads are allowed under Only on this Mac (the user asked for them) and recorded")
    func downloads() async throws {
        let gate = EgressGate(policy: .localOnly, store: MemEgressStore())
        try await gate.authorize(.modelDownload, url: URL(string: "https://huggingface.co/x")!)
        #expect(await gate.entries.first?.blocked == false)
    }

    @Test("other policies allow cloud requests")
    func allowed() async throws {
        for policy in [RoutingPolicy.localFirst, .cloudAllowed] {
            let gate = EgressGate(policy: policy, store: MemEgressStore())
            try await gate.authorize(.cloudInference, url: cloud, provider: "openai")
            #expect(await gate.cloudAllowed() == nil)
        }
    }

    @Test("repeated identical requests are merged into one counted line; no content is stored")
    func merging() async throws {
        let gate = EgressGate(store: MemEgressStore())
        for _ in 0..<5 { try await gate.authorize(.cloudInference, url: cloud, provider: "openai") }
        try await gate.authorize(.modelDownload, url: URL(string: "https://example.com/a?secret=1")!)
        let e = await gate.entries
        #expect(e.count == 2 && e[0].count == 5)
        #expect(e[1].host == "example.com")
        let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        #expect(!json.contains("secret"))
    }

    @Test("the ledger is capped")
    func capped() async throws {
        let clock = Clock()
        let gate = EgressGate(store: MemEgressStore(), now: { clock.now })
        for i in 0..<(EgressGate.maxEntries + 20) {
            clock.advance(days: 1)
            try await gate.authorize(.modelDownload, url: URL(string: "https://h\(i).example")!)
        }
        #expect(await gate.entries.count == EgressGate.maxEntries)
    }

    @Test("the monthly token limit blocks cloud requests once reached, and resets next month")
    func budget() async throws {
        let clock = Clock()
        let gate = EgressGate(store: MemEgressStore(), now: { clock.now })
        await gate.setMonthlyTokenCap(1_000)
        try await gate.authorize(.cloudInference, url: cloud)
        await gate.recordCloudTokens(600)
        try await gate.authorize(.cloudInference, url: cloud)
        await gate.recordCloudTokens(500)
        await #expect(throws: EgressError.budgetExhausted(usedTokens: 1_100, capTokens: 1_000)) {
            try await gate.authorize(.cloudInference, url: cloud)
        }
        try await gate.authorize(.modelDownload, url: cloud)       // the limit is for cloud models only
        clock.advance(days: 31)
        try await gate.authorize(.cloudInference, url: cloud)
        #expect(await gate.tokensThisMonth == 0)
        await gate.setMonthlyTokenCap(nil)
        #expect(await gate.monthlyTokenCap == nil)
    }

    @Test("usage and the limit survive a restart")
    func persisted() async {
        let store = MemEgressStore()
        let a = EgressGate(store: store)
        await a.setMonthlyTokenCap(5_000); await a.recordCloudTokens(123)
        let b = EgressGate(store: store)
        let cap = await b.monthlyTokenCap, used = await b.tokensThisMonth
        #expect(cap == 5_000 && used == 123)
    }
}

// MARK: Real sockets: does anything reach the "cloud"?

private actor Hits {
    private(set) var n = 0, chats = 0
    func hit(chat: Bool = false) { n += 1; if chat { chats += 1 } }
}

private func fakeCloud(_ hits: Hits) -> some ApplicationProtocol {
    let router = Router()
    router.post("v1/chat/completions") { _, _ -> Response in
        await hits.hit(chat: true)
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"cloud says hi\"}}]}\n\ndata: [DONE]\n\n"
        return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init(byteBuffer: ByteBuffer(string: body)))
    }
    router.get("v1/models") { _, _ -> Response in await hits.hit(); return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"data":[]}"#))) }
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
}

@Suite("Egress enforcement (real sockets)")
struct EgressEnforcementTests {

    private func service(port: Int, policy: RoutingPolicy, gate: EgressGate) async -> InferenceService {
        setenv("EGRESS_TEST_KEY", "k", 1)
        let credentials = CredentialStore(service: "egress-test-\(UUID().uuidString)")
        await credentials.registerEnvVarKey("EGRESS_TEST_KEY", for: "fake-cloud")
        let config = RemoteAPIProvider.Config(
            id: "fake-cloud", baseURL: URL(string: "http://localhost:\(port)/v1")!, modelIdentifier: "m",
            capabilities: [.textGeneration, .streaming], envVarKey: "EGRESS_TEST_KEY")
        let registry = ModelRegistry()
        try? await registry.discover(localDirectory: nil, remoteConfigs: [config], credentials: credentials, gate: gate)
        return InferenceService(registry: registry, policy: policy, gate: gate)
    }

    private func run(_ svc: InferenceService, pin: String? = nil) async throws -> String {
        var text = ""
        for try await e in try await svc.generate(messages: [Message(role: .user, content: "hi")], tools: [], pin: pin) {
            if case .token(let t) = e { text += t }
        }
        return text
    }

    @Test("Only on this Mac: not one connection reaches the cloud server, even when the model is named")
    func zeroOutbound() async throws {
        let hits = Hits()
        try await fakeCloud(hits).test(.live) { client in
            let port = try #require(client.port)
            let gate = EgressGate(policy: .localOnly, store: MemEgressStore())
            let svc = await service(port: port, policy: .localOnly, gate: gate)
            await #expect(throws: (any Error).self) { _ = try await run(svc, pin: "fake-cloud") }
            await #expect(throws: (any Error).self) { _ = try await run(svc) }
            _ = await svc.availableModels()                      // health checks must not leak either
            #expect(await hits.n == 0)
        }
    }

    @Test("Local first with no local model: the request does go out, is recorded, and counts against the limit")
    func allowedAndCounted() async throws {
        let hits = Hits()
        try await fakeCloud(hits).test(.live) { client in
            let port = try #require(client.port)
            let gate = EgressGate(policy: .localFirst, store: MemEgressStore())
            let svc = await service(port: port, policy: .localFirst, gate: gate)
            #expect(try await run(svc) == "cloud says hi")
            #expect(await hits.chats == 1)
            #expect(await gate.entries.first { $0.purpose == .cloudInference && !$0.blocked }?.host == "localhost")
            #expect(await gate.tokensThisMonth > 0)
        }
    }

    @Test("Once the monthly limit is used, cloud requests stop before anything is sent")
    func limitStopsRequests() async throws {
        let hits = Hits()
        try await fakeCloud(hits).test(.live) { client in
            let port = try #require(client.port)
            let gate = EgressGate(policy: .localFirst, store: MemEgressStore())
            await gate.setMonthlyTokenCap(1)
            let svc = await service(port: port, policy: .localFirst, gate: gate)
            _ = try await run(svc)                                // first call goes through, uses > 1 token
            await #expect(throws: EgressError.self) { _ = try await run(svc) }
            #expect(await hits.chats == 1)
        }
    }

    @Test("Switching to Only on this Mac takes effect immediately")
    func switchPolicy() async throws {
        let hits = Hits()
        try await fakeCloud(hits).test(.live) { client in
            let port = try #require(client.port)
            let gate = EgressGate(policy: .cloudAllowed, store: MemEgressStore())
            let svc = await service(port: port, policy: .cloudAllowed, gate: gate)
            _ = try await run(svc)
            await svc.setPolicy(.localOnly)
            try await Task.sleep(for: .milliseconds(50))
            await #expect(throws: (any Error).self) { _ = try await run(svc) }
            #expect(await hits.chats == 1)
        }
    }

    @Test("a ledger written with the retired web purposes still loads, minus those lines")
    func retiredPurposes() throws {
        let json = """
        {"entries":[
          {"id":"\(UUID().uuidString)","date":"2026-01-01T00:00:00Z","purpose":"webFetch","host":"a.example","blocked":false,"count":1},
          {"id":"\(UUID().uuidString)","date":"2026-01-02T00:00:00Z","purpose":"cloudInference","host":"api.openai.com","provider":"openai","blocked":false,"count":2}
        ],"monthlyTokens":{"2026-01":42},"monthlyTokenCap":1000}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(EgressState.self, from: Data(json.utf8))
        #expect(state.entries.map(\.host) == ["api.openai.com"])
        #expect(state.monthlyTokens == ["2026-01": 42] && state.monthlyTokenCap == 1000)
    }
}
