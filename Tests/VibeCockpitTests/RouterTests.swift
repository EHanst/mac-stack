import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("Router")
struct RouterTests {

    private func candidate(_ id: String, local: Bool, health: ProviderHealth = .healthy,
                           caps: ProviderCapabilities = [.textGeneration, .streaming]) -> RouteCandidate {
        RouteCandidate(id: id, capabilities: caps, isLocal: local, health: health)
    }

    private var all: [RouteCandidate] {
        [candidate("openai", local: false),
         candidate("local:bonsai", local: true),
         candidate("anthropic", local: false)]
    }

    private let gen = RoutingRequest(task: .textGeneration)

    @Test("localOnly never returns cloud providers")
    func localOnly() {
        #expect(Router.plan(policy: .localOnly, request: gen, candidates: all) == ["local:bonsai"])
    }

    @Test("localOnly with no local provider yields an empty plan")
    func localOnlyEmpty() {
        let cloudOnly = all.filter { !$0.isLocal }
        #expect(Router.plan(policy: .localOnly, request: gen, candidates: cloudOnly).isEmpty)
    }

    @Test("localFirst orders local before cloud, cloud sorted by id")
    func localFirst() {
        #expect(Router.plan(policy: .localFirst, request: gen, candidates: all)
                == ["local:bonsai", "anthropic", "openai"])
    }

    @Test("unavailable providers are skipped; degraded ones are kept")
    func healthFiltering() {
        let c = [candidate("local:a", local: true, health: .unavailable("no weights")),
                 candidate("local:b", local: true, health: .degraded("not loaded")),
                 candidate("openai", local: false)]
        #expect(Router.plan(policy: .localFirst, request: gen, candidates: c) == ["local:b", "openai"])
    }

    @Test("capability filtering: embedding request skips generation-only providers")
    func capabilityFiltering() {
        let c = all + [candidate("embedder", local: true, caps: [.embedding])]
        let plan = Router.plan(policy: .localFirst, request: RoutingRequest(task: .embedding), candidates: c)
        #expect(plan == ["embedder"])
    }

    @Test("cloudAllowed prefers cloud when the prompt exceeds the local context limit")
    func cloudWhenTooBig() {
        let req = RoutingRequest(task: .textGeneration, estimatedTokens: 90_000, localContextLimit: 64_000)
        let plan = Router.plan(policy: .cloudAllowed, request: req, candidates: all)
        #expect(plan == ["anthropic", "openai", "local:bonsai"])
    }

    @Test("cloudAllowed prefers cloud under memory pressure, local otherwise")
    func cloudUnderPressure() {
        let pressured = RoutingRequest(task: .textGeneration, underMemoryPressure: true)
        #expect(Router.plan(policy: .cloudAllowed, request: pressured, candidates: all).first == "anthropic")
        #expect(Router.plan(policy: .cloudAllowed, request: gen, candidates: all).first == "local:bonsai")
    }

    @Test("localFirst ignores context size and pressure (cloud only on failure)")
    func localFirstIgnoresSize() {
        let req = RoutingRequest(task: .textGeneration, estimatedTokens: 90_000,
                                 localContextLimit: 64_000, underMemoryPressure: true)
        #expect(Router.plan(policy: .localFirst, request: req, candidates: all).first == "local:bonsai")
    }
}
