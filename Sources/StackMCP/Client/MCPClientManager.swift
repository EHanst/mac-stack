import Foundation
import MCP
import System
import os
#if SWIFT_PACKAGE
import StackCore
#endif

public enum ExternalServerStatus: Sendable, Equatable {
    case stopped
    case starting
    case running(toolCount: Int)
    case failed(String)
}

/// A tool that lives on an external MCP server. Everything about it is untrusted: its output is
/// fenced and taints the conversation, and every call asks first, whatever the conversation looks like.
public struct ExternalMCPTool: AgentToolHandler {
    let server: ExternalMCPServer
    let remoteName: String
    let client: Client
    public let toolDefinition: Tool

    public var requiredScope: ClientScope { .toolsExec }
    public var producesUntrustedContent: Bool { true }
    public var alwaysRequiresApproval: Bool { true }
    public var approvalIdentity: ClientIdentity? { server.identity }

    public func approvalSummary(arguments: [String: Value]) -> String {
        let args = arguments.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        return "Call “\(remoteName)” on \(server.name)" + (args.isEmpty ? "" : " (\(String(args.prefix(300))))")
    }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let (content, isError) = try await client.callTool(name: remoteName, arguments: arguments)
        // A server can return a lot; keep what reaches the model bounded.
        let bounded: [Tool.Content] = content.map {
            if case .text(let t, let a, let m) = $0, t.count > MCPClientManager.maxResultCharacters {
                return .text(text: String(t.prefix(MCPClientManager.maxResultCharacters)) + "\n…(cut)", annotations: a, _meta: m)
            }
            return $0
        }
        if isError == true { throw ExternalToolError.serverReportedError(bounded.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined(separator: "\n")) }
        return bounded
    }
}

public enum ExternalToolError: LocalizedError {
    case serverReportedError(String)
    public var errorDescription: String? {
        switch self { case .serverReportedError(let m): m.isEmpty ? "The tool reported an error." : m }
    }
}

/// Starts the user's external MCP servers, lists their tools and hands them to the agent as
/// `AgentToolHandler`s. One server failing never affects the others.
public actor MCPClientManager {
    public static let maxResultCharacters = 64_000
    static let maxDescriptionCharacters = 400
    static let connectTimeout: Duration = .seconds(20)

    /// `pipes` must outlive `client`: the transport holds only their raw descriptor numbers, and a
    /// deallocated `Pipe` closes them, so a late write would land in whatever file reuses the number.
    private struct Running { let process: Process; let client: Client; let pipes: [Pipe]; var tools: [ExternalMCPTool] }

    private let store: any ExternalServerStore
    private(set) var servers: [ExternalMCPServer]
    private var running: [String: Running] = [:]
    private var statuses: [String: ExternalServerStatus] = [:]
    private var onChange: (@Sendable () -> Void)?
    private let log = Logger(subsystem: "com.vibecockpit", category: "MCPClientManager")

    public init(store: any ExternalServerStore = FileExternalServerStore(url: FileExternalServerStore.defaultURL())) {
        self.store = store
        self.servers = (try? store.load()) ?? []
    }

    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) { onChange = handler }

    public var list: [(server: ExternalMCPServer, status: ExternalServerStatus)] {
        servers.map { ($0, statuses[$0.id] ?? .stopped) }
    }

    /// Every tool from every running server.
    public func tools() -> [any AgentToolHandler] {
        servers.compactMap { running[$0.id]?.tools }.flatMap { $0 }
    }

    /// Start everything that is enabled (call at launch).
    public func startAll() async {
        for s in servers where s.enabled { await start(s.id) }
    }

    public func stopAll() async { for id in Array(running.keys) { await stop(id) } }

    @discardableResult
    public func add(_ server: ExternalMCPServer) async throws -> ExternalMCPServer {
        var s = server
        var id = s.id.isEmpty ? ExternalMCPServer.makeID(from: s.name) : s.id
        let base = id; var n = 2
        while servers.contains(where: { $0.id == id }) { id = "\(base)_\(n)"; n += 1 }
        s.id = id
        servers.append(s)
        try store.save(servers)
        if s.enabled { await start(id) } else { changed() }
        return s
    }

    public func remove(_ id: String) async {
        await stop(id)
        servers.removeAll { $0.id == id }
        statuses[id] = nil
        try? store.save(servers)
        changed()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].enabled = enabled
        try? store.save(servers)
        if enabled { await start(id) } else { await stop(id) }
    }

    public func start(_ id: String) async {
        guard let server = servers.first(where: { $0.id == id }), running[id] == nil else { return }
        statuses[id] = .starting; changed()
        do {
            let r = try await Self.launch(server)
            running[id] = r
            statuses[id] = .running(toolCount: r.tools.count)
            log.info("external MCP server \(id, privacy: .public) up with \(r.tools.count) tools")
        } catch {
            statuses[id] = .failed(error.localizedDescription)
            log.error("external MCP server \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        changed()
    }

    public func stop(_ id: String) async {
        if let r = running.removeValue(forKey: id) {
            await r.client.disconnect()
            if r.process.isRunning { r.process.terminate() }
        }
        statuses[id] = .stopped
        changed()
    }

    private func changed() { onChange?() }

    // MARK: Launching

    private static func launch(_ server: ExternalMCPServer) async throws -> Running {
        let process = Process()
        let inPipe = Pipe(), outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [server.command] + server.args
        var env = ProcessInfo.processInfo.environment
        // A Dock-launched app has a bare PATH; tools installed with Homebrew/npm wouldn't be found.
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        for (k, v) in server.env { env[k] = v }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A write to a server that has exited must fail with EPIPE, not kill this app with SIGPIPE.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: outPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: inPipe.fileHandleForWriting.fileDescriptor))
        let client = Client(name: "Kororo", version: "1.0.0")
        // Whichever comes first wins: the tool list, the 20 s timeout, or the program exiting.
        // (A task group would wait for a dead server's request that never completes.)
        let tools: [ExternalMCPTool]
        do {
            tools = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[ExternalMCPTool], Error>) in
                let once = Once()
                let work = Task {
                    // Keep the pipes open until this task is done with the transport, even if `launch`
                    // has already given up on it (timeout, early exit).
                    defer { withExtendedLifetime((inPipe, outPipe)) {} }
                    do {
                        _ = try await client.connect(transport: transport)
                        var out: [ExternalMCPTool] = []
                        var cursor: String?
                        repeat {
                            let page = try await client.listTools(cursor: cursor)
                            for t in page.tools { out.append(makeTool(t, server: server, client: client)) }
                            cursor = page.nextCursor
                        } while cursor != nil && out.count < 200
                        if once.first() { cont.resume(returning: out) }
                    } catch {
                        if once.first() { cont.resume(throwing: error) }
                    }
                }
                process.terminationHandler = { _ in
                    if once.first() { work.cancel(); cont.resume(throwing: ExternalServerError.exited) }
                }
                Task {
                    try? await Task.sleep(for: connectTimeout)
                    if once.first() { work.cancel(); cont.resume(throwing: ExternalServerError.timedOut) }
                }
            }
        } catch {
            Task { await client.disconnect() }
            if process.isRunning { process.terminate() }
            throw error
        }
        process.terminationHandler = nil
        return Running(process: process, client: client, pipes: [inPipe, outPipe], tools: tools)
    }

    static func makeTool(_ t: Tool, server: ExternalMCPServer, client: Client) -> ExternalMCPTool {
        // The description is text from the server that the model reads: cap it and say where it's from.
        let description = "[from \(server.name)] " + String((t.description ?? "").prefix(maxDescriptionCharacters))
        let exposed = Tool(name: ExternalMCPServer.exposedToolName(server: server.id, tool: t.name),
                           description: description, inputSchema: t.inputSchema)
        return ExternalMCPTool(server: server, remoteName: t.name, client: client, toolDefinition: exposed)
    }
}

public enum ExternalServerError: LocalizedError {
    case timedOut, exited
    public var errorDescription: String? {
        switch self {
        case .timedOut: "The server didn't answer within 20 seconds."
        case .exited: "The program stopped right after starting. Check the command and its arguments."
        }
    }
}

/// True for exactly one caller.
private final class Once: @unchecked Sendable {
    private let l = NSLock(); private var done = false
    func first() -> Bool { l.withLock { if done { return false }; done = true; return true } }
}
