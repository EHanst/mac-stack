import Testing
import Foundation
import MCP
@testable import StackCore
@testable import StackMCP

private actor Scripted: ModelProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities = [.textGeneration, .streaming]
    let reply: String
    init(id: String = "local:test", reply: String) { self.id = id; self.reply = reply }
    func generate(messages: [StackCore.Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let reply = self.reply
        return AsyncThrowingStream { c in c.yield(.token(reply)); c.yield(.finished(.stop)); c.finish() }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { [] }
    func healthCheck() async -> ProviderHealth { .healthy }
}

private func text(_ content: [Tool.Content]) -> String {
    for item in content { if case .text(let t, _, _) = item { return t } }
    return ""
}

private func connect(_ host: MCPToolHost, scopes: ScopeBox) async throws -> (Client, Server) {
    let server = await host.makeServer(scopes: scopes)
    let (clientT, serverT) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverT)
    let client = Client(name: "t", version: "1")
    _ = try await client.connect(transport: clientT)
    return (client, server)
}

private func tempProject(files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
    let dir = root.appendingPathComponent(WorkspacePromptStore.folder)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    return root
}

private func trust() -> PromptTrust { PromptTrust(defaults: UserDefaults(suiteName: "trust-\(UUID().uuidString)")!) }

@Suite("Project prompts")
struct WorkspacePromptStoreTests {

    @Test("finds markdown prompts in .vibe/prompts, unapproved at first")
    func finds() async throws {
        let root = try tempProject(files: [
            "review.md": "---\ntitle: Team review\nslash: teamreview\n---\nReview {{file}}",
            "notes.txt": "not a prompt",
        ])
        let store = WorkspacePromptStore(roots: { [("Demo", root)] }, trust: trust())
        let all = await store.all()
        #expect(all.count == 1)
        #expect(all[0].prompt.title == "Team review")
        #expect(all[0].prompt.slash == "teamreview")
        #expect(all[0].prompt.scope == .workspace)
        #expect(all[0].approved == false)
        #expect(await store.approvedPrompts().isEmpty)
    }

    @Test("approving offers the prompt; changing the file withdraws the approval")
    func approval() async throws {
        let root = try tempProject(files: ["a.md": "Do the thing"])
        let store = WorkspacePromptStore(roots: { [("Demo", root)] }, trust: trust())
        let id = try #require(await store.all().first?.id)
        await store.approve(id: id)
        #expect(await store.approvedPrompts().map(\.body) == ["Do the thing"])

        let file = root.appendingPathComponent(WorkspacePromptStore.folder + "/a.md")
        try "Do something else entirely".write(to: file, atomically: true, encoding: .utf8)
        #expect(await store.approvedPrompts().isEmpty)
        #expect(await store.all().first?.approved == false)
    }

    @Test("symlinks and oversized files are ignored")
    func skipsRisky() async throws {
        let root = try tempProject(files: ["ok.md": "fine", "big.md": String(repeating: "x", count: WorkspacePromptStore.maxBytes + 1)])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).md")
        try "outside the project".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(WorkspacePromptStore.folder + "/link.md"), withDestinationURL: outside)
        let store = WorkspacePromptStore(roots: { [("Demo", root)] }, trust: trust())
        #expect(await store.all().map(\.fileName) == ["ok.md"])
    }

    @Test("a project without the folder simply has none")
    func none() async {
        let store = WorkspacePromptStore(roots: { [("Empty", FileManager.default.temporaryDirectory)] }, trust: trust())
        #expect(await store.all().isEmpty)
    }
}

@Suite("Prompts over MCP")
struct MCPPromptTests {

    private func host(_ prompts: [SavedPrompt], reply: String = "") async -> MCPToolHost {
        let registry = ModelRegistry()
        await registry.register(Scripted(reply: reply))
        let host = MCPToolHost(inference: InferenceService(registry: registry))
        await host.setPromptProvider { prompts }
        return host
    }

    private let sample = [
        SavedPrompt(title: "Ship it", body: "Release {{project}} on {{date}} using {{clipboard}}", slash: "ship"),
        SavedPrompt(id: "abc", title: "No shortcut", body: "Plain text"),
    ]

    @Test("an app without the prompts permission sees none and can't fetch one")
    func needsScope() async throws {
        let (client, server) = try await connect(await host(sample), scopes: ScopeBox([.models, .chat]))
        #expect(try await client.listPrompts().prompts.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await client.getPrompt(name: "ship") }
        await client.disconnect(); await server.stop()
    }

    @Test("new apps don't get the prompts permission by default")
    func notDefault() { #expect(!ClientScope.defaultForNewClient.contains(.prompts)) }

    @Test("with the permission: prompts are listed by shortcut or id, blanks become arguments, date is filled in, clipboard is not read")
    func listAndGet() async throws {
        let (client, server) = try await connect(await host(sample), scopes: ScopeBox([.prompts]))
        let listed = try await client.listPrompts().prompts
        #expect(Set(listed.map(\.name)) == ["ship", "abc"])
        let ship = try #require(listed.first { $0.name == "ship" })
        #expect(Set(ship.arguments?.map(\.name) ?? []) == ["project", "clipboard"])   // no "date"

        let got = try await client.getPrompt(name: "ship", arguments: ["project": "Demo", "clipboard": "PASTED"])
        guard case .text(let body) = got.messages.first?.content else { Issue.record("expected text"); return }
        #expect(body.hasPrefix("Release Demo on "))
        #expect(body.hasSuffix(" using PASTED"))
        #expect(!body.contains("{{date}}"))

        let missing = try await client.getPrompt(name: "ship", arguments: ["project": "Demo"])
        guard case .text(let partial) = missing.messages.first?.content else { return }
        #expect(partial.hasSuffix("using {{clipboard}}"))   // never silently filled from the pasteboard

        await #expect(throws: (any Error).self) { _ = try await client.getPrompt(name: "nope") }
        await client.disconnect(); await server.stop()
    }

    @Test("optimize_prompt needs the chat permission and returns the rewrite")
    func optimizeTool() async throws {
        let reply = "<improved>Fix the crash in `load()` and say why.</improved>"
        let h = await host([], reply: reply)
        let scopes = ScopeBox([.models])
        let (client, server) = try await connect(h, scopes: scopes)
        let denied = try await client.callTool(name: "optimize_prompt", arguments: ["prompt": "fix crash in `load()`"])
        #expect(denied.isError == true)

        scopes.scopes = [.chat]
        let ok = try await client.callTool(name: "optimize_prompt", arguments: ["prompt": "fix crash in `load()`", "target": "claude"])
        #expect(ok.isError != true)
        #expect(text(ok.content) == "Fix the crash in `load()` and say why.")
        await client.disconnect(); await server.stop()
    }

    @Test("optimize_prompt hands back the original, with the reason, when the rewrite drops a word it can't restore")
    func optimizeRejects() async throws {
        let h = await host([], reply: "<improved>Fix the failure in `load()` that happens whenever the user opens the settings screen after the app has been idle for a long time.</improved>")
        let (client, server) = try await connect(h, scopes: ScopeBox([.chat]))
        let r = try await client.callTool(name: "optimize_prompt", arguments: ["prompt": "fix the crash in `load()` that happens whenever the user opens the settings screen after the app has been idle for a long time"])
        #expect(text(r.content).hasPrefix("fix the crash in `load()`"))
        #expect(text(r.content).contains("not changed"))
        await client.disconnect(); await server.stop()
    }
}
