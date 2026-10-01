import Testing
import Foundation
@testable import StackCore

private actor Named: ModelProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities = [.textGeneration, .streaming]
    let fail: Bool
    init(_ id: String, fail: Bool = false) { self.id = id; self.fail = fail }
    func generate(messages: [StackCore.Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let id = self.id, fail = self.fail
        return AsyncThrowingStream { c in
            if fail { c.finish(throwing: ProviderError.httpError(500)) }
            else { c.yield(.token(id)); c.yield(.finished(.stop)); c.finish() }
        }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
    func healthCheck() async -> ProviderHealth { .healthy }
}

private func answer(_ svc: InferenceService, onRoute: (@Sendable (RouteNotice) -> Void)? = nil) async throws -> String {
    var text = ""
    for try await e in try await svc.generate(messages: [StackCore.Message(role: .user, content: "hi")], tools: [], onRoute: onRoute) {
        if case .token(let t) = e { text += t }
    }
    return text
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock(); private var items: [RouteNotice] = []
    func add(_ n: RouteNotice) { lock.withLock { items.append(n) } }
    var all: [RouteNotice] { lock.withLock { items } }
}

@Suite("System load")
struct SystemLoadTests {
    @Test("strained when memory is short, the Mac is hot, or Low Power Mode is on")
    func strained() {
        #expect(!SystemLoad().isStrained)
        #expect(SystemLoad(memory: .warning).isStrained)
        #expect(SystemLoad(thermal: .serious).isStrained)
        #expect(!SystemLoad(thermal: .fair).isStrained)
        #expect(SystemLoad(lowPowerMode: true).isStrained)
    }

    @Test("explains itself in plain words")
    func words() {
        #expect(SystemLoad().explanation == nil)
        #expect(SystemLoad(memory: .critical, thermal: .serious).explanation == "This Mac is very short on memory and it is running hot")
        #expect(SystemLoad(lowPowerMode: true).explanation == "Low Power Mode is on")
    }

    @Test("the governor reports only real changes")
    func changes() async {
        let governor = SystemGovernor()
        let seen = Log2()
        await governor.onChange { seen.add($0) }
        await governor.update { $0.memory = .warning }
        await governor.update { $0.memory = .warning }
        await governor.update { $0.memory = .normal }
        #expect(seen.all.map(\.memory) == [.warning, .normal])
    }
    private final class Log2: @unchecked Sendable {
        private let lock = NSLock(); private var items: [SystemLoad] = []
        func add(_ l: SystemLoad) { lock.withLock { items.append(l) } }
        var all: [SystemLoad] { lock.withLock { items } }
    }
}

@Suite("Governor routing and fallback notices")
struct GovernorRoutingTests {

    private func service(policy: RoutingPolicy, governor: SystemGovernor?, localFails: Bool = false) async -> InferenceService {
        let registry = ModelRegistry()
        await registry.register(Named("local:bonsai", fail: localFails))
        await registry.register(Named("openai"))
        return InferenceService(registry: registry, policy: policy, governor: governor)
    }

    @Test("Cloud allowed: a strained Mac sends work to the cloud; a healthy one stays local")
    func strainedRoutesToCloud() async throws {
        let governor = SystemGovernor()
        let svc = await service(policy: .cloudAllowed, governor: governor)
        #expect(try await answer(svc) == "local:bonsai")
        await governor.update { $0.memory = .warning }
        #expect(try await answer(svc) == "openai")
        await governor.update { $0.memory = .normal }
        #expect(try await answer(svc) == "local:bonsai")
    }

    @Test("Local first stays local when strained: the user's choice wins over the governor")
    func localFirstStays() async throws {
        let governor = SystemGovernor()
        await governor.update { $0.thermal = .critical }
        let svc = await service(policy: .localFirst, governor: governor)
        #expect(try await answer(svc) == "local:bonsai")
    }

    @Test("a request that falls back to the cloud says so, per request")
    func fallbackNotice() async throws {
        let log = Log()
        let svc = await service(policy: .localFirst, governor: nil, localFails: true)
        #expect(try await answer(svc, onRoute: { log.add($0) }) == "openai")
        let kinds = log.all.map(\.kind)
        #expect(kinds.count == 2)
        if case .fellBack(let from, let to, _) = kinds.last {
            #expect(from == "local:bonsai" && to == "openai")
        } else { Issue.record("expected a fallback notice, got \(kinds)") }
    }
}
