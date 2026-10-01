import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import MCP
import StackMCP
@testable import StackCore
@testable import StackHTTP

// MARK: Stubs

private actor Probe {
    private(set) var started = 0
    private(set) var terminated = 0
    private(set) var lastMessages: [StackCore.Message] = []
    func start(_ m: [StackCore.Message]) { started += 1; lastMessages = m }
    func end() { terminated += 1 }
}

private actor StubModel: ModelProvider {
    enum Behavior: Sendable {
        case tokens([String])
        case delayedTokens(milliseconds: Int, [String])
        case endless
        case failBeforeOutput
    }
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities
    let behavior: Behavior
    let probe: Probe

    init(id: String, behavior: Behavior = .tokens(["Hello", " world"]), probe: Probe = Probe(),
         capabilities: ProviderCapabilities = [.textGeneration, .streaming]) {
        self.id = id; self.behavior = behavior; self.probe = probe; self.capabilities = capabilities
    }

    func generate(messages: [StackCore.Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let behavior = self.behavior, probe = self.probe
        return AsyncThrowingStream { c in
            let task = Task {
                await probe.start(messages)
                switch behavior {
                case .tokens(let ts):
                    for t in ts { c.yield(.token(t)) }
                    c.yield(.usage(GenerationUsage(promptTokens: 7, completionTokens: ts.count)))
                    c.yield(.finished(.stop)); c.finish()
                case .delayedTokens(let ms, let ts):
                    try? await Task.sleep(for: .milliseconds(ms))
                    for t in ts { c.yield(.token(t)) }
                    c.yield(.finished(.stop)); c.finish()
                case .endless:
                    while !Task.isCancelled {
                        c.yield(.token("tick "))
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    c.finish()
                case .failBeforeOutput:
                    c.finish(throwing: ProviderError.httpError(500))
                }
            }
            c.onTermination = { _ in task.cancel(); Task { await probe.end() } }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [0.5, -0.25] } }
    func healthCheck() async -> ProviderHealth { .healthy }
}

private final class MemoryStore: ClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [APIClient] = []
    func load() throws -> [APIClient] { lock.withLock { clients } }
    func save(_ c: [APIClient]) throws { lock.withLock { clients = c } }
}

// MARK: Harness

private struct Harness {
    let server: StackAPIServer
    let token: String
    let clients: ClientRegistry

    static func make(
        _ providers: [StubModel] = [StubModel(id: "local:bonsai")],
        policy: RoutingPolicy = .localFirst,
        scopes: Set<ClientScope> = ClientScope.defaultForNewClient,
        origins: Set<String> = [],
        keepAlive: Duration = .seconds(10),
        mcp: Bool = false
    ) async throws -> Harness {
        let registry = ModelRegistry()
        for p in providers { await registry.register(p) }
        let inference = InferenceService(registry: registry, policy: policy)
        let clients = try ClientRegistry(store: MemoryStore())
        let (client, token) = try await clients.create(name: "Test app", scopes: scopes)
        _ = client
        var config = APIServerConfiguration(port: 0)
        config.allowedOrigins = origins
        config.keepAlive = keepAlive
        let sessions = mcp ? MCPHTTPSessions(host: MCPToolHost(inference: inference)) : nil
        return Harness(server: StackAPIServer(inference: inference, clients: clients, mcp: sessions, configuration: config),
                       token: token, clients: clients)
    }

    var auth: HTTPFields { [.authorization: "Bearer \(token)"] }

    func chatBody(_ extra: String = "", stream: Bool = false, model: String? = nil) -> ByteBuffer {
        let m = model.map { #""model":"\#($0)","# } ?? ""
        return ByteBuffer(string: #"{\#(m)"messages":[{"role":"user","content":"hi"}],"stream":\#(stream)\#(extra)}"#)
    }
}

private func errorCode(_ body: ByteBuffer) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any],
          let err = obj["error"] as? [String: Any] else { return nil }
    return err["code"] as? String
}

private func sseEvents(_ body: ByteBuffer) -> [String] {
    String(buffer: body).components(separatedBy: "\n\n").compactMap {
        $0.hasPrefix("data: ") ? String($0.dropFirst(6)) : nil
    }
}

// MARK: Tests

@Suite("StackAPIServer")
struct StackAPIServerTests {

    // MARK: Access control

    @Test("/healthz needs no token")
    func healthz() async throws {
        let h = try await Harness.make()
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("ok"))
            }
        }
    }

    @Test("missing or wrong token is 401 with a Bearer challenge")
    func unauthorized() async throws {
        let h = try await Harness.make()
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.headers[.wwwAuthenticate] == "Bearer")
                #expect(errorCode(response.body) == "invalid_api_key")
            }
            try await client.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Bearer vc_nope"]) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/models", method: .get, headers: [.authorization: "Basic abc"]) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("a revoked token stops working")
    func revoked() async throws {
        let h = try await Harness.make()
        let id = try #require(await h.clients.all.first?.id)
        try await h.clients.revoke(id)
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: h.auth) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("a key without the scope gets 403")
    func wrongScope() async throws {
        let h = try await Harness.make(scopes: [.models])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: h.auth) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody()) { response in
                #expect(response.status == .forbidden)
                #expect(errorCode(response.body) == "insufficient_scope")
            }
            try await client.execute(uri: "/v1/embeddings", method: .post, headers: h.auth,
                                     body: ByteBuffer(string: #"{"input":"x"}"#)) { #expect($0.status == .forbidden) }
        }
    }

    @Test("a Host that isn't this machine is refused (DNS rebinding)")
    func badHost() async throws {
        let h = try await Harness.make()
        try await h.server.makeApplication().test(.live) { client in
            let port = try #require(client.port)
            try await TestClient.withClient(host: "localhost", port: port, configuration: .init()) { raw in
                let request = TestClient.Request("/v1/models", method: .get, authority: "evil.example", headers: h.auth)
                let response = try await raw.execute(request)
                #expect(response.status.code == 421)
                #expect(response.body.flatMap(errorCode) == "invalid_host")
            }
        }
    }

    @Test("requests carrying a browser Origin are refused unless listed")
    func origins() async throws {
        let h = try await Harness.make(origins: ["http://localhost:3000"])
        let origin = HTTPField.Name("Origin")!
        try await h.server.makeApplication().test(.live) { client in
            var evil = h.auth; evil[origin] = "https://evil.example"
            try await client.execute(uri: "/v1/models", method: .get, headers: evil) { response in
                #expect(response.status == .forbidden)
                #expect(errorCode(response.body) == "origin_not_allowed")
                #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == nil)
            }
            var ok = h.auth; ok[origin] = "http://localhost:3000"
            try await client.execute(uri: "/v1/models", method: .get, headers: ok) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/chat/completions", method: .options, headers: h.auth) { #expect($0.status == .forbidden) }
        }
    }

    @Test("unknown endpoints get an OpenAI-shaped 404")
    func notFound() async throws {
        let h = try await Harness.make()
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/nope", method: .get, headers: h.auth) { response in
                #expect(response.status == .notFound)
                #expect(errorCode(response.body) == "unknown_endpoint")
            }
        }
    }

    // MARK: Models

    @Test("/v1/models lists local models first")
    func models() async throws {
        let h = try await Harness.make([StubModel(id: "openai"), StubModel(id: "local:bonsai")])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: h.auth) { response in
                let obj = try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                let data = obj?["data"] as? [[String: Any]] ?? []
                #expect(obj?["object"] as? String == "list")
                #expect(data.compactMap { $0["id"] as? String } == ["local:bonsai", "openai"])
                #expect(data.first?["owned_by"] as? String == "this-mac")
            }
        }
    }

    // MARK: Chat

    @Test("non-streaming chat returns one completion with usage")
    func chat() async throws {
        let probe = Probe()
        let h = try await Harness.make([StubModel(id: "local:bonsai", probe: probe)])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody()) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let obj = try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                let choice = (obj?["choices"] as? [[String: Any]])?.first
                #expect((choice?["message"] as? [String: Any])?["content"] as? String == "Hello world")
                #expect(choice?["finish_reason"] as? String == "stop")
                #expect((obj?["usage"] as? [String: Any])?["prompt_tokens"] as? Int == 7)
            }
        }
        #expect(await probe.lastMessages.last?.content == "hi")
    }

    @Test("streaming chat sends role, deltas, finish and [DONE] as server-sent events")
    func chatStreaming() async throws {
        let h = try await Harness.make()
        try await h.server.makeApplication().test(.live) { client in
            let body = h.chatBody(#","stream_options":{"include_usage":true}"#, stream: true)
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: body) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/event-stream")
                let events = sseEvents(response.body)
                #expect(events.last == "[DONE]")
                let chunks = events.dropLast().compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                let deltas = chunks.compactMap { (($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]) }
                #expect(deltas.first?["role"] as? String == "assistant")
                #expect(deltas.compactMap { $0["content"] as? String }.joined() == "Hello world")
                let finishes = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String }
                #expect(finishes == ["stop"])
                #expect(chunks.contains { ($0["usage"] as? [String: Any])?["completion_tokens"] as? Int == 2 })
            }
        }
    }

    @Test("a slow start is bridged with keep-alive comments")
    func keepAlive() async throws {
        let slow = StubModel(id: "local:bonsai", behavior: .delayedTokens(milliseconds: 400, ["late"]))
        let h = try await Harness.make([slow], keepAlive: .milliseconds(60))
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody(stream: true)) { response in
                let text = String(buffer: response.body)
                #expect(text.contains(": keep-alive"))
                #expect(text.contains("late"))
                #expect(text.hasSuffix("data: [DONE]\n\n"))
            }
        }
    }

    @Test("a provider failing before any output is an HTTP error, not a broken stream")
    func failureBeforeOutput() async throws {
        let h = try await Harness.make([StubModel(id: "local:bonsai", behavior: .failBeforeOutput)])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody()) { response in
                #expect(response.status.code == 502)
                #expect(errorCode(response.body) == "upstream_error")
            }
        }
    }

    @Test("bad JSON and missing messages are 400")
    func badRequests() async throws {
        let h = try await Harness.make()
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: ByteBuffer(string: "{nope")) { response in
                #expect(response.status == .badRequest)
                #expect(errorCode(response.body) == "invalid_json")
            }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: ByteBuffer(string: #"{"messages":[]}"#)) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    // MARK: Model choice and tools

    @Test("tools are refused for the local model, allowed for a named cloud model")
    func tools() async throws {
        let h = try await Harness.make([StubModel(id: "local:bonsai"), StubModel(id: "openai")])
        let tools = #","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]"#
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody(tools)) { response in
                #expect(response.status == .badRequest)
                #expect(errorCode(response.body) == "tools_unsupported")
            }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth,
                                     body: h.chatBody(tools, model: "local:bonsai")) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth,
                                     body: h.chatBody(tools, model: "openai")) { #expect($0.status == .ok) }
        }
    }

    @Test("naming a model uses exactly that model; unknown names are 404")
    func pinning() async throws {
        let cloud = Probe(), local = Probe()
        let h = try await Harness.make([
            StubModel(id: "local:bonsai", probe: local), StubModel(id: "openai", probe: cloud),
        ])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth,
                                     body: h.chatBody(model: "openai")) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth,
                                     body: h.chatBody(model: "auto")) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth,
                                     body: h.chatBody(model: "gpt-nope")) { response in
                #expect(response.status == .notFound)
                #expect(errorCode(response.body) == "model_not_found")
            }
        }
        #expect(await cloud.started == 1)
        #expect(await local.started == 1)
    }

    @Test("'Only on this Mac' blocks cloud models even when named")
    func privacySwitch() async throws {
        let cloud = Probe()
        let h = try await Harness.make([StubModel(id: "local:bonsai"), StubModel(id: "openai", probe: cloud)], policy: .localOnly)
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth,
                                     body: h.chatBody(model: "openai")) { response in
                #expect(response.status == .forbidden)
                #expect(errorCode(response.body) == "blocked_by_privacy_setting")
            }
        }
        #expect(await cloud.started == 0)
    }

    // MARK: Embeddings

    @Test("embeddings return one vector per input")
    func embeddings() async throws {
        let h = try await Harness.make([StubModel(id: "local:bge", capabilities: [.embedding])])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/embeddings", method: .post, headers: h.auth,
                                     body: ByteBuffer(string: #"{"input":["a","b"]}"#)) { response in
                #expect(response.status == .ok)
                let obj = try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                let data = obj?["data"] as? [[String: Any]] ?? []
                #expect(data.count == 2)
                #expect(data.first?["embedding"] as? [Double] == [0.5, -0.25])
                #expect(data.last?["index"] as? Int == 1)
                #expect(obj?["model"] as? String == "local:bge")
            }
        }
    }

    // MARK: Disconnect

    @Test("a client that disconnects mid-stream cancels the generation")
    func disconnectCancels() async throws {
        let probe = Probe()
        let h = try await Harness.make([StubModel(id: "local:bonsai", behavior: .endless, probe: probe)])
        try await h.server.makeApplication().test(.live) { client in
            let port = try #require(client.port)
            var request = URLRequest(url: URL(string: "http://localhost:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(h.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(String(buffer: h.chatBody(stream: true)).utf8)

            let reader = Task {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                var lines = 0
                for try await _ in bytes.lines { lines += 1; if lines >= 6 { break } }
                return lines
            }
            #expect(try await reader.value >= 6)
            #expect(await probe.started == 1)
            // `bytes` went out of scope with the task: the connection is closed.
            var waited = 0
            while await probe.terminated == 0, waited < 100 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
            #expect(await probe.terminated >= 1, "generation should stop when the client goes away")
        }
    }

    @Test("after a fallback the response says which model really answered")
    func servedBy() async throws {
        let h = try await Harness.make([
            StubModel(id: "local:bonsai", behavior: .failBeforeOutput),
            StubModel(id: "openai", behavior: .tokens(["from cloud"])),
        ])
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody()) { response in
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("X-Kororo-Served-By")!] == "openai")
                #expect(response.headers[HTTPField.Name("X-Kororo-Fallback-From")!] == "local:bonsai")
                let obj = try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                #expect(obj?["model"] as? String == "openai")
            }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h.auth, body: h.chatBody(stream: true)) { response in
                let chunks = sseEvents(response.body).dropLast().compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                #expect(chunks.dropFirst().allSatisfy { $0["model"] as? String == "openai" })
            }
        }
    }

    // MARK: MCP over HTTP

    private func mcpClient(port: Int, token: String) async throws -> Client {
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:\(port)/mcp")!, streaming: false,
            requestModifier: { var r = $0; r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); return r })
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: transport)
        return client
    }

    private func text(_ content: [Tool.Content]) -> String {
        for item in content { if case .text(let t, _, _) = item { return t } }
        return ""
    }

    @Test("an MCP client can connect over HTTP with its key, list tools and call chat")
    func mcpHTTP() async throws {
        let h = try await Harness.make(mcp: true)
        try await h.server.makeApplication().test(.live) { client in
            let port = try #require(client.port)
            let mcp = try await mcpClient(port: port, token: h.token)
            #expect(Set(try await mcp.listTools().tools.map(\.name)) == ["list_models", "chat", "embed", "optimize_prompt"])
            let answer = try await mcp.callTool(name: "chat", arguments: ["prompt": "hi"])
            #expect(text(answer.content) == "Hello world")
            #expect(text(try await mcp.callTool(name: "list_models").content).contains("local:bonsai"))
            await mcp.disconnect()
        }
    }

    @Test("over HTTP a key only gets the tools its permissions allow")
    func mcpScopes() async throws {
        let h = try await Harness.make(scopes: [.models], mcp: true)
        try await h.server.makeApplication().test(.live) { client in
            let port = try #require(client.port)
            let mcp = try await mcpClient(port: port, token: h.token)
            #expect(try await mcp.listTools().tools.map(\.name) == ["list_models"])
            #expect(try await mcp.callTool(name: "chat", arguments: ["prompt": "hi"]).isError == true)
            await mcp.disconnect()
        }
    }

    @Test("/mcp needs a key, and one app can't use another app's session")
    func mcpAuthAndIsolation() async throws {
        let h = try await Harness.make(mcp: true)
        let (_, otherToken) = try await h.clients.create(name: "Other")
        let initialize = ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let json: HTTPFields = [.contentType: "application/json", .accept: "application/json, text/event-stream"]
        try await h.server.makeApplication().test(.live) { client in
            try await client.execute(uri: "/mcp", method: .post, headers: json, body: initialize) { #expect($0.status == .unauthorized) }

            var mine = json; mine[.authorization] = "Bearer \(h.token)"
            var sessionID: String?
            try await client.execute(uri: "/mcp", method: .post, headers: mine, body: initialize) { response in
                #expect(response.status == .ok, "\(response.status) \(String(buffer: response.body))")
                sessionID = response.headers[HTTPField.Name("MCP-Session-Id")!]
            }
            let id = try #require(sessionID)

            var theirs = json; theirs[.authorization] = "Bearer \(otherToken)"; theirs[HTTPField.Name("MCP-Session-Id")!] = id
            try await client.execute(uri: "/mcp", method: .post, headers: theirs,
                                     body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
