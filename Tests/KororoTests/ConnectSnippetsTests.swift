import Testing
import Foundation
@testable import KororoCore
@testable import StackCore
@testable import StackMCP

@Suite("Connect snippets")
struct ConnectSnippetsTests {
    private let snippets = ConnectSnippets.all(baseURL: "http://127.0.0.1:11500/v1", socketPath: "/Users/me/.vibecockpit/mcp.sock")

    private func text(_ id: String) -> String { snippets.first { $0.id == id }!.text }

    @Test("every snippet points at the real address")
    func addresses() {
        #expect(text("claude-desktop").contains("/Users/me/.vibecockpit/mcp.sock"))
        #expect(text("cursor").contains("http://127.0.0.1:11500/mcp"))
        #expect(text("openai-python").contains(#"base_url="http://127.0.0.1:11500/v1""#))
        #expect(text("curl").contains("http://127.0.0.1:11500/v1/chat/completions"))
    }

    @Test("JSON snippets are valid JSON and the key placeholder is filled in when known")
    func json() throws {
        for id in ["claude-desktop", "cursor"] {
            #expect(throws: Never.self) { _ = try JSONSerialization.jsonObject(with: Data(text(id).utf8)) }
        }
        let keyed = ConnectSnippets.all(baseURL: "http://127.0.0.1:1/v1", socketPath: "/s", key: "vc_abc")
        #expect(keyed.first { $0.id == "cursor" }!.text.contains("Bearer vc_abc"))
        #expect(!text("cursor").contains("vc_"))
    }

    @Test("Claude Desktop needs no key and no installed helper")
    func noKey() {
        #expect(!text("claude-desktop").contains("Bearer"))
        #expect(text("claude-desktop").contains("/usr/bin/nc"))
        #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/nc"))
    }
}

@Suite("Connection check")
@MainActor
struct ConnectionCheckTests {
    @Test("off → says how to turn it on; on → reports API and socket")
    func check() async throws {
        let d = UserDefaults(suiteName: "chk-\(UUID().uuidString)")!
        struct Mem: ClientStore { func load() throws -> [APIClient] { [] }; func save(_ c: [APIClient]) throws {} }
        let model = APISharingModel(inference: InferenceService(registry: ModelRegistry()), store: Mem(), defaults: d, port: 0)
        let off = await model.runCheck(socketPath: "/tmp/none.sock")
        #expect(off.count == 1 && !off[0].ok && off[0].text.contains("Sharing is off"))

        let path = "/tmp/vc-chk-\(UUID().uuidString.prefix(8)).sock"
        let service = MCPService(host: MCPToolHost())
        try await service.start(socketPath: path)
        await model.setEnabled(true)
        for _ in 0..<100 { if case .running = model.status { break }; try await Task.sleep(for: .milliseconds(20)) }
        let on = await model.runCheck(socketPath: path)
        #expect(on[0].ok && on[0].text.contains("API answering"))
        #expect(on[1].ok == false)                       // no model registered
        #expect(on[2].ok)                                // socket accepts
        await model.stopServer(); await service.stop()
    }
}
