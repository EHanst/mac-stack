import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

private func model(_ name: String, kind: ModelInfo.Kind = .local, caps: ProviderCapabilities = [.textGeneration, .streaming],
                   health: ProviderHealth) -> ModelInfo {
    ModelInfo(id: kind == .local ? "local:\(name)" : name, displayName: name, kind: kind, capabilities: caps, health: health)
}

@Suite("MenuBarStatus")
struct MenuBarStatusTests {

    @Test("first run: asks the user to open the app")
    func onboarding() {
        let s = MenuBarStatus.make(models: [], isGenerating: false, onboardingNeeded: true)
        #expect(s.level == .attention && s.title == "Set up VibeCockpit")
    }

    @Test("a healthy local chat model is 'Ready' and says it runs on this Mac")
    func readyLocal() {
        let s = MenuBarStatus.make(models: [model("Bonsai-27B", health: .healthy)], isGenerating: false, onboardingNeeded: false)
        #expect(s.level == .ready && s.title == "Ready — Bonsai-27B" && s.detail == "Running on this Mac")
    }

    @Test("a healthy cloud model says so")
    func readyCloud() {
        let s = MenuBarStatus.make(models: [model("openai", kind: .remote, health: .healthy)], isGenerating: false, onboardingNeeded: false)
        #expect(s.detail == "Running in the cloud")
    }

    @Test("generating is 'Working…' and keeps the model name")
    func busy() {
        let s = MenuBarStatus.make(models: [model("Bonsai-27B", health: .healthy)], isGenerating: true, onboardingNeeded: false)
        #expect(s.level == .busy && s.title == "Working…" && s.detail == "Bonsai-27B")
    }

    @Test("a local model that hasn't loaded yet is 'Loading', not an error")
    func warming() {
        let s = MenuBarStatus.make(models: [model("Bonsai-27B", health: .degraded("Model not yet loaded"))], isGenerating: false, onboardingNeeded: false)
        #expect(s.level == .warming && s.title.hasPrefix("Loading Bonsai-27B"))
    }

    @Test("an unavailable model shows the reason (e.g. not enough memory)")
    func unavailable() {
        let s = MenuBarStatus.make(models: [model("Bonsai-27B", health: .unavailable("Not enough free GPU memory"))], isGenerating: false, onboardingNeeded: false)
        #expect(s.level == .attention && s.detail == "Not enough free GPU memory")
    }

    @Test("the embedder alone doesn't count as a chat model")
    func embedderOnly() {
        let s = MenuBarStatus.make(models: [model("embed-bge", caps: [.embedding], health: .healthy)], isGenerating: false, onboardingNeeded: false)
        #expect(s.level == .attention && s.title == "No model")
    }

    @Test("a healthy embedder doesn't hide an unavailable chat model")
    func embedderDoesNotMask() {
        let s = MenuBarStatus.make(models: [model("embed-bge", caps: [.embedding], health: .healthy),
                                            model("Bonsai-27B", health: .unavailable("x"))], isGenerating: false, onboardingNeeded: false)
        #expect(s.level == .attention)
    }

    @Test("indexing is mentioned while ready")
    func indexing() {
        let s = MenuBarStatus.make(models: [model("Bonsai-27B", health: .healthy)], isGenerating: false, onboardingNeeded: false, indexing: true)
        #expect(s.detail == "Indexing your workspace…")
    }
}

private final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus
    var registerResult: LoginItemStatus?          // status after register(); nil = unchanged
    var throwOnRegister = false
    var registerCalls = 0, unregisterCalls = 0
    init(_ status: LoginItemStatus) { _status = status }
    var status: LoginItemStatus { lock.withLock { _status } }
    struct Refused: LocalizedError { var errorDescription: String? { "refused" } }
    func register() throws {
        registerCalls += 1
        if throwOnRegister { throw Refused() }
        lock.withLock { _status = registerResult ?? .enabled }
    }
    func unregister() throws { unregisterCalls += 1; lock.withLock { _status = .disabled } }
}

@MainActor
@Suite("LoginItemModel")
struct LoginItemModelTests {

    @Test("turning it on registers and reports enabled; off unregisters")
    func toggle() {
        let fake = FakeLoginItem(.disabled)
        let m = LoginItemModel(controller: fake)
        #expect(!m.isOn)
        m.setEnabled(true)
        #expect(m.isOn && m.status == .enabled && fake.registerCalls == 1 && m.message == nil)
        m.setEnabled(false)
        #expect(!m.isOn && fake.unregisterCalls == 1)
    }

    @Test("pending approval keeps the switch on and explains what to do")
    func approval() {
        let fake = FakeLoginItem(.disabled)
        fake.registerResult = .requiresApproval
        let m = LoginItemModel(controller: fake)
        m.setEnabled(true)
        #expect(m.isOn && m.status == .requiresApproval)
        #expect(m.message?.contains("Login Items") == true)
    }

    @Test("a refused registration is reported, not swallowed")
    func failure() {
        let fake = FakeLoginItem(.disabled)
        fake.throwOnRegister = true
        let m = LoginItemModel(controller: fake)
        m.setEnabled(true)
        #expect(!m.isOn)
        #expect(m.message?.contains("refused") == true)
    }

    @Test("outside an installed app it is unavailable and says why")
    func unavailable() {
        let fake = FakeLoginItem(.unavailable)
        fake.registerResult = .unavailable         // registering can't make it available
        let m = LoginItemModel(controller: fake)
        #expect(!m.isAvailable)
        m.setEnabled(true)
        #expect(m.message?.contains("Applications folder") == true)
    }

    @Test("refresh picks up changes made in System Settings")
    func refresh() {
        let fake = FakeLoginItem(.enabled)
        let m = LoginItemModel(controller: fake)
        try? fake.unregister()
        m.refresh()
        #expect(!m.isOn)
    }
}

@MainActor
@Suite("Routing policy")
struct RoutingPolicyStateTests {

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "routing-test-\(UUID().uuidString)")! }

    @Test("defaults to Local first, changes are observable and persisted across launches")
    func persisted() async {
        let d = defaults()
        let a = AppServices(defaults: d)
        #expect(a.routingPolicy == .localFirst)
        await a.setRoutingPolicy(.localOnly)
        #expect(a.routingPolicy == .localOnly)
        #expect(AppServices(defaults: d).routingPolicy == .localOnly)     // next launch
    }

    @Test("an unreadable stored value falls back to Local first")
    func garbage() {
        let d = defaults()
        d.set("somethingElse", forKey: "routingPolicy")
        #expect(AppServices(defaults: d).routingPolicy == .localFirst)
    }
}

@Suite("RoutingPolicy labels")
struct RoutingPolicyLabelTests {
    @Test("every privacy position has a distinct plain-language title and explanation")
    func labels() {
        let titles = RoutingPolicy.allCases.map(\.title)
        #expect(Set(titles).count == titles.count && titles.allSatisfy { !$0.isEmpty })
        #expect(RoutingPolicy.allCases.allSatisfy { $0.summary.count > 20 })
        #expect(RoutingPolicy.localOnly.summary.contains("Nothing ever leaves this Mac"))
    }
}
