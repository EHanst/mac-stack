import Testing
import Foundation
import MCP
import Darwin
@testable import StackCore
@testable import StackMCP

private final class MemStore: ApprovalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: SavedApproval] = [:]
    func load() throws -> [String: SavedApproval] { lock.withLock { data } }
    func save(_ a: [String: SavedApproval]) throws { lock.withLock { data = a } }
}

private actor ScriptedApprover: ToolApprover {
    private var answers: [ApprovalDecision]
    private(set) var asked: [ApprovalRequest] = []
    init(_ answers: [ApprovalDecision]) { self.answers = answers }
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        asked.append(request)
        return answers.isEmpty ? .deny : answers.removeFirst()
    }
}

private let cursor = ClientIdentity(key: "client:1", name: "Cursor")
private let zed = ClientIdentity(key: "client:2", name: "Zed")
private func request(_ scope: ClientScope, as who: ClientIdentity = cursor) -> ApprovalRequest {
    ApprovalRequest(client: who, toolName: "t", scope: scope, summary: "do it")
}

@Suite("Tool approval")
struct ToolApprovalTests {

    @Test("reading never asks; writing and running do")
    func policy() {
        for s in [ClientScope.models, .chat, .embeddings, .toolsRead] { #expect(!ApprovalPolicy.needsApproval(s)) }
        #expect(ApprovalPolicy.needsApproval(.toolsWrite))
        #expect(ApprovalPolicy.needsApproval(.toolsExec))
    }

    @Test("without an approver, changing things is refused but reading is fine")
    func noApprover() async {
        let gate = ToolGate(memory: ApprovalMemory(store: MemStore()), approver: nil)
        #expect(await gate.allows(request(.toolsRead)))
        #expect(await gate.allows(request(.toolsWrite)) == false)
    }

    @Test("allow once asks every time; deny refuses")
    func onceAndDeny() async {
        let approver = ScriptedApprover([.allowOnce, .allowOnce, .deny])
        let gate = ToolGate(memory: ApprovalMemory(store: MemStore()), approver: approver)
        #expect(await gate.allows(request(.toolsWrite)))
        #expect(await gate.allows(request(.toolsWrite)))
        #expect(await gate.allows(request(.toolsWrite)) == false)
        #expect(await approver.asked.count == 3)
    }

    @Test("always allow is remembered per app and per kind of action, and survives a restart")
    func always() async {
        let store = MemStore()
        let approver = ScriptedApprover([.allowAlways, .deny, .deny])
        let gate = ToolGate(memory: ApprovalMemory(store: store), approver: approver)
        #expect(await gate.allows(request(.toolsWrite)))
        #expect(await gate.allows(request(.toolsWrite)))                 // remembered: no prompt
        #expect(await approver.asked.count == 1)
        #expect(await gate.allows(request(.toolsExec)) == false)          // a different kind still asks
        #expect(await gate.allows(request(.toolsWrite, as: zed)) == false) // another app still asks

        let restarted = ToolGate(memory: ApprovalMemory(store: store), approver: nil)
        #expect(await restarted.allows(request(.toolsWrite)))
    }

    @Test("forgetting takes the permission back")
    func forget() async {
        let memory = ApprovalMemory(store: MemStore())
        await memory.remember(cursor, .toolsWrite)
        await memory.remember(cursor, .toolsExec)
        await memory.forget(key: cursor.key, scope: .toolsExec)
        #expect(await memory.isAllowed(cursor, .toolsWrite))
        #expect(await memory.isAllowed(cursor, .toolsExec) == false)
        #expect(await memory.all.map(\.entry.name) == ["Cursor"])
        await memory.forget(key: cursor.key)
        #expect(await memory.all.isEmpty)
    }

    @Test("the approvals file is owner-only")
    func fileMode() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).json")
        let memory = ApprovalMemory(store: FileApprovalStore(url: url))
        await memory.remember(cursor, .toolsWrite)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(await ApprovalMemory(store: FileApprovalStore(url: url)).isAllowed(cursor, .toolsWrite))
    }
}

// MARK: Through the MCP host

private actor RunLog { private(set) var runs = 0; func ran() { runs += 1 } }

private struct FakeWriteTool: AgentToolHandler {
    let toolDefinition = Tool(name: "fake_write", description: "test", inputSchema: .object(["type": "object"]))
    var requiredScope: ClientScope { .toolsWrite }
    let log: RunLog
    func approvalSummary(arguments: [String: Value]) -> String { "Fake write" }
    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        await log.ran()
        return [.text(text: "written", annotations: nil, _meta: nil)]
    }
}

private func firstText(_ content: [Tool.Content]) -> String {
    for item in content { if case .text(let t, _, _) = item { return t } }
    return ""
}

@Suite("Approval through MCP")
struct MCPApprovalTests {

    private func connect(host: MCPToolHost, identity: ClientIdentity = cursor) async throws -> (Client, Server) {
        let box = ScopeBox(Set(ClientScope.allCases), identity: identity)
        let server = await host.makeServer(scopes: box)
        let (c, s) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: s)
        let client = Client(name: "t", version: "1")
        _ = try await client.connect(transport: c)
        return (client, server)
    }

    @Test("a denied write doesn't run; an allowed one does; 'always' stops the asking")
    func gating() async throws {
        let log = RunLog()
        let approver = ScriptedApprover([.deny, .allowOnce, .allowAlways])
        let host = MCPToolHost(gate: ToolGate(memory: ApprovalMemory(store: MemStore()), approver: approver))
        await host.register(FakeWriteTool(log: log))
        let (client, server) = try await connect(host: host)

        let denied = try await client.callTool(name: "fake_write")
        #expect(denied.isError == true)
        #expect(firstText(denied.content).contains("didn't allow"))
        #expect(await log.runs == 0)

        #expect(firstText(try await client.callTool(name: "fake_write").content) == "written")
        #expect(firstText(try await client.callTool(name: "fake_write").content) == "written")   // asks: allowAlways
        #expect(firstText(try await client.callTool(name: "fake_write").content) == "written")   // remembered
        #expect(await approver.asked.count == 3)
        #expect(await approver.asked.first?.client == cursor)
        #expect(await approver.asked.first?.summary == "Fake write")
        #expect(await log.runs == 3)
        await client.disconnect(); await server.stop()
    }

    @Test("a host with no approver refuses writes")
    func noGate() async throws {
        let log = RunLog()
        let host = MCPToolHost()
        await host.register(FakeWriteTool(log: log))
        let (client, server) = try await connect(host: host)
        #expect(try await client.callTool(name: "fake_write").isError == true)
        #expect(await log.runs == 0)
        await client.disconnect(); await server.stop()
    }

    @Test("a local socket tool is identified by the name it introduces itself with")
    func socketIdentity() async throws {
        let approver = ScriptedApprover([.allowOnce])
        let log = RunLog()
        let host = MCPToolHost(gate: ToolGate(memory: ApprovalMemory(store: MemStore()), approver: approver))
        await host.register(FakeWriteTool(log: log))
        let path = "/tmp/vc-appr-\(UUID().uuidString.prefix(8)).sock"
        let service = MCPService(host: host)
        try await service.start(socketPath: path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withCString { src in _ = memcpy(dst.baseAddress!, src, strlen(src) + 1) } }
        _ = withUnsafePointer(to: addr) { Darwin.connect(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size)) }
        let client = Client(name: "claude-desktop", version: "1")
        _ = try await client.connect(transport: SocketConnectionTransport(fd: fd))

        #expect(firstText(try await client.callTool(name: "fake_write").content) == "written")
        #expect(await approver.asked.first?.client.key == "socket:claude-desktop")
        await client.disconnect(); await service.stop()
    }
}
