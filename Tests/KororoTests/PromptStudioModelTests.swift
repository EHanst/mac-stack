import Testing
import Foundation
@testable import KororoCore
@testable import StackCore

private actor Replier: ModelProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities
    let reply: String
    let delayMs: Int
    init(id: String, reply: String, delayMs: Int = 0, capabilities: ProviderCapabilities = [.textGeneration, .streaming]) {
        self.id = id; self.reply = reply; self.delayMs = delayMs; self.capabilities = capabilities
    }
    func generate(messages: [Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let reply = self.reply, delay = delayMs
        return AsyncThrowingStream { c in
            let task = Task {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled { c.finish(throwing: CancellationError()); return }
                c.yield(.token(reply)); c.yield(.finished(.stop)); c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
    func healthCheck() async -> ProviderHealth { .healthy }
}

@MainActor
@Suite("PromptStudioModel")
struct PromptStudioModelTests {

    private func make(_ providers: [Replier], policy: RoutingPolicy = .localFirst, clipboard: String? = nil)
        async -> (PromptStudioModel, UserDefaults)
    {
        let registry = ModelRegistry()
        for p in providers { await registry.register(p) }
        let inference = InferenceService(registry: registry, policy: policy)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "studio-\(UUID().uuidString)")!
        let model = PromptStudioModel(
            library: PromptLibrary(directory: dir), optimizer: PromptOptimizer(inference: inference),
            plannedModel: { await inference.plannedModel() },
            listModels: { await inference.availableModels() },
            defaults: defaults, clipboard: { clipboard },
            today: { Date(timeIntervalSince1970: 31_536_000 + 43_200) })
        await model.reload()
        await model.refreshModel()
        return (model, defaults)
    }

    private func waitForEnd(_ model: PromptStudioModel) async {
        for _ in 0..<200 {
            if !model.isRunning { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("starts with the shipped prompts")
    func loads() async {
        let (m, _) = await make([Replier(id: "local:a", reply: "")])
        #expect(m.prompts.count == BuiltInPrompts.starters.count)
    }

    @Test("slash shortcuts match by prefix")
    func slash() async {
        let (m, _) = await make([Replier(id: "local:a", reply: "")])
        #expect(m.slashMatches("re").compactMap(\.slash).sorted() == ["refactor", "review"])
        #expect(m.slashMatches("zzz").isEmpty)
    }

    @Test("built-in blanks fill themselves; the rest are asked for")
    func variables() async throws {
        let (m, _) = await make([Replier(id: "local:a", reply: "")], clipboard: "PASTED")
        m.workspaceName = "Demo"
        let p = SavedPrompt(title: "t", body: "In {{workspace}} on {{date}}: {{clipboard}} then {{goal}}")
        #expect(m.fieldsToAsk(for: p) == ["goal"])
        #expect(m.text(for: p, values: ["goal": "ship"]) == "In Demo on 1971-01-01: PASTED then ship")
    }

    @Test("an empty clipboard leaves the blank to be asked for")
    func emptyClipboard() async {
        let (m, _) = await make([Replier(id: "local:a", reply: "")], clipboard: nil)
        #expect(m.fieldsToAsk(for: SavedPrompt(title: "t", body: "{{clipboard}}")) == ["clipboard"])
    }

    @Test("a model-specific version is used for that kind of model")
    func variants() async {
        let (m, _) = await make([Replier(id: "local:bonsai", reply: "")])
        #expect(m.profile.family == "local")
        let p = SavedPrompt(title: "t", body: "long form", modelVariants: ["local": "short form"])
        #expect(m.text(for: p) == "short form")
    }

    @Test("Improve: streams to a review and accepting lets the user undo")
    func improveFlow() async {
        let reply = "<improved>Fix the crash in `load()` and explain why.</improved><changes>- asked why</changes>"
        let (m, _) = await make([Replier(id: "local:a", reply: reply)])
        m.startOptimize(draft: "fix crash in `load()`", mode: .improve, intent: "debug")
        #expect(m.isRunning)
        await waitForEnd(m)
        guard case .review(let o) = m.phase else { Issue.record("expected review, got \(m.phase)"); return }
        #expect(o.didChange && o.model == "local:a")
        m.accepted(text: o.improved, replacing: "fix crash in `load()`")
        #expect(m.undoDraft == "fix crash in `load()`")
        #expect(m.takeUndo() == "fix crash in `load()`")
        #expect(m.takeUndo() == nil)
    }

    @Test("Improve never touches the saved prompts")
    func improveIsIsolated() async {
        let (m, _) = await make([Replier(id: "local:a", reply: "<improved>Fix the crash in the loader.</improved>")])
        let before = m.prompts.map(\.id)
        m.startOptimize(draft: "fix crash in loader", mode: .improve, intent: nil)
        await waitForEnd(m)
        #expect(m.prompts.map(\.id) == before)
    }

    @Test("cancel returns to idle right away")
    func cancel() async {
        let (m, _) = await make([Replier(id: "local:a", reply: "<improved>x</improved>", delayMs: 500)])
        m.startOptimize(draft: "fix the crash please", mode: .improve, intent: nil)
        #expect(m.isRunning)
        m.cancelOptimize()
        #expect(m.phase == .idle)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(m.phase == .idle)
    }

    @Test("a refused pin (cloud while Only-on-this-Mac) shows a plain-language failure")
    func refused() async {
        let (m, defaults) = await make([Replier(id: "openai", reply: "x"), Replier(id: "local:a", reply: "y")], policy: .localOnly)
        m.optimizerPin = "openai"
        #expect(defaults.string(forKey: PromptStudioModel.pinKey) == "openai")
        m.startOptimize(draft: "fix the crash please", mode: .improve, intent: nil)
        await waitForEnd(m)
        guard case .failed(let message) = m.phase else { Issue.record("expected failure, got \(m.phase)"); return }
        #expect(message.contains("off this Mac"))
    }

    @Test("utility models are not offered as optimizers")
    func choices() async {
        let (m, _) = await make([
            Replier(id: "local:chat", reply: ""),
            Replier(id: "local:embed", reply: "", capabilities: [.embedding]),
            Replier(id: "local:draft", reply: "", capabilities: [.textGeneration, .speculativeDraft]),
        ])
        #expect(m.choices.map(\.id) == ["local:chat"])
    }

    @Test("the rewrite is tailored to the model that will answer, not the one that rewrites")
    func profileIsTargets() async {
        let (m, _) = await make([Replier(id: "anthropic", reply: "")])
        #expect(m.profile.family == "claude")
    }

    @Test("importing a prompt never steals an existing shortcut")
    func importKeepsSlash() async throws {
        let (m, _) = await make([Replier(id: "local:a", reply: "")])
        let p = try await m.importMarkdown("---\ntitle: Mine\nslash: review\n---\nDo it", fallbackTitle: "x")
        #expect(p.slash == nil)
        #expect(m.prompts.first { $0.slash == "review" }?.builtIn == true)
    }

    @Test("word diff marks what was added and removed and round-trips the text")
    func wordDiff() {
        let segs = WordDiff.segments(from: "fix the crash", to: "fix the crash in load and say why")
        #expect(segs.first?.kind == .same)
        #expect(segs.filter { $0.kind == .added }.map(\.text).joined() == " in load and say why")
        #expect(segs.filter { $0.kind != .added }.map(\.text).joined() == "fix the crash")
        let swap = WordDiff.segments(from: "make it fast", to: "make it quick")
        #expect(swap.filter { $0.kind == .removed }.map(\.text) == ["fast"])
        #expect(swap.filter { $0.kind == .added }.map(\.text) == ["quick"])
        #expect(WordDiff.segments(from: "same", to: "same") == [.init(text: "same", kind: .same)])
    }
}
