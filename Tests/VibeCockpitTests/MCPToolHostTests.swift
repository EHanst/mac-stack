import Testing
import Foundation
import Darwin
import MCP
@testable import StackCore
@testable import StackMCP

private actor Model: ModelProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities
    init(id: String, capabilities: ProviderCapabilities) { self.id = id; self.capabilities = capabilities }
    func generate(messages: [StackCore.Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let last = messages.last?.content ?? ""
        return AsyncThrowingStream { c in
            c.yield(.token("echo: ")); c.yield(.token(last)); c.yield(.finished(.stop)); c.finish()
        }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { [Float($0.count), 1] } }
    func healthCheck() async -> ProviderHealth { .healthy }
}

private func makeHost() async -> MCPToolHost {
    let registry = ModelRegistry()
    await registry.register(Model(id: "local:test", capabilities: [.textGeneration, .streaming]))
    await registry.register(Model(id: "local:embed", capabilities: [.embedding]))
    return MCPToolHost(inference: InferenceService(registry: registry))
}

private func firstText(_ content: [Tool.Content]) -> String {
    for item in content { if case .text(let t, _, _) = item { return t } }
    return ""
}

private func connectClient(path: String) async throws -> (Client, Initialize.Result) {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        path.withCString { src in _ = memcpy(dst.baseAddress!, src, strlen(src) + 1) }
    }
    let rc = withUnsafePointer(to: addr) {
        Darwin.connect(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size))
    }
    #expect(rc == 0)
    let client = Client(name: "test", version: "1")
    let result = try await client.connect(transport: SocketConnectionTransport(fd: fd))
    return (client, result)
}

@Suite("MCP tools and scopes")
struct MCPToolHostTests {

    @Test("model tools exist without a workspace; workspace tools do not")
    func workspaceless() async {
        let host = await makeHost()
        let names = await host.allTools().map { $0.toolDefinition.name }
        #expect(Set(names) == ["list_models", "chat", "embed"])
        #expect(await host.hasWorkspace == false)
    }

    @Test("a client only sees and can only run tools its permissions allow, and changes apply live")
    func scopes() async throws {
        let host = await makeHost()
        let scopes = ScopeBox([.models])
        let server = await host.makeServer(scopes: scopes)
        let (clientT, serverT) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverT)
        let client = Client(name: "t", version: "1")
        _ = try await client.connect(transport: clientT)

        #expect(try await client.listTools().tools.map(\.name) == ["list_models"])
        let denied = try await client.callTool(name: "chat", arguments: ["prompt": "hi"])
        #expect(denied.isError == true)
        #expect(firstText(denied.content).contains("isn't allowed"))

        scopes.scopes = [.models, .chat]
        #expect(Set(try await client.listTools().tools.map(\.name)) == ["list_models", "chat"])
        let ok = try await client.callTool(name: "chat", arguments: ["prompt": "hi"])
        #expect(ok.isError != true)
        #expect(firstText(ok.content) == "echo: hi")

        await client.disconnect()
        await server.stop()
    }

    @Test("list_models, chat and embed work end to end")
    func modelTools() async throws {
        let host = await makeHost()
        let server = await host.makeServer(scopes: ScopeBox(Set(ClientScope.allCases)))
        let (clientT, serverT) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverT)
        let client = Client(name: "t", version: "1")
        _ = try await client.connect(transport: clientT)

        let models = firstText(try await client.callTool(name: "list_models").content)
        #expect(models.contains("local:test — on this Mac, ready"))

        let chat = try await client.callTool(name: "chat", arguments: ["prompt": "ping", "system": "be brief"])
        #expect(firstText(chat.content) == "echo: ping")
        let bad = try await client.callTool(name: "chat", arguments: ["prompt": "x", "model": "nope"])
        #expect(bad.isError == true)

        let embed = try await client.callTool(name: "embed", arguments: ["texts": ["ab", "abcd"]])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(firstText(embed.content).utf8)) as? [String: Any])
        #expect(json["model"] as? String == "local:embed")
        #expect((json["embeddings"] as? [[Double]]) == [[2, 1], [4, 1]])

        await client.disconnect()
        await server.stop()
    }
}

@Suite("MCP Unix socket")
struct MCPSocketTests {

    private func socketPath() -> String { "/tmp/vc-mcp-\(UUID().uuidString.prefix(8)).sock" }

    @Test("several clients connect at once, each is served, and one leaving doesn't affect the others")
    func multiClient() async throws {
        let path = socketPath()
        let service = MCPService(host: await makeHost())
        try await service.start(socketPath: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let (a, infoA) = try await connectClient(path: path)
        let (b, _) = try await connectClient(path: path)
        #expect(infoA.serverInfo.name == "vibecockpit")

        #expect(Set(try await a.listTools().tools.map(\.name)) == ["list_models", "chat", "embed"])
        #expect(firstText(try await b.callTool(name: "chat", arguments: ["prompt": "from b"]).content) == "echo: from b")

        await a.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(firstText(try await b.callTool(name: "chat", arguments: ["prompt": "still here"]).content) == "echo: still here")

        let (c, _) = try await connectClient(path: path)   // a later client is accepted too
        #expect(try await c.listTools().tools.count == 3)

        await b.disconnect(); await c.disconnect()
        await service.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a stale socket file from a crashed run is replaced")
    func staleSocket() async throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        let service = MCPService(host: await makeHost())
        try await service.start(socketPath: path)
        let (client, _) = try await connectClient(path: path)
        #expect(try await client.listTools().tools.isEmpty == false)
        await client.disconnect()
        await service.stop()
    }

    @Test("a path too long for a Unix socket is refused clearly")
    func longPath() async {
        let listener = UnixSocketListener(path: "/tmp/" + String(repeating: "x", count: 200)) { _ in }
        #expect(throws: UnixSocketListener.ListenerError.pathTooLong) { try listener.start() }
    }
}
