import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
import StackMCP
#endif

/// Settings view of the external MCP servers the user added.
@MainActor
@Observable
public final class ExternalServersModel {
    public struct Row: Identifiable, Equatable {
        public let server: ExternalMCPServer
        public let status: ExternalServerStatus
        public var id: String { server.id }
    }
    public private(set) var rows: [Row] = []
    public private(set) var lastError: String?
    private let manager: MCPClientManager

    public init(manager: MCPClientManager) {
        self.manager = manager
        Task { [weak self] in
            await manager.setChangeHandler { Task { @MainActor in await self?.reload() } }
            await self?.reload()
        }
    }

    public func reload() async {
        rows = await manager.list.map { Row(server: $0.server, status: $0.status) }
    }

    /// `arguments` is a plain command-line style string ("-y @scope/server /path"); quotes group words.
    public func add(name: String, command: String, arguments: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !command.isEmpty else { lastError = "Give it a name and a command."; return }
        lastError = nil
        do {
            _ = try await manager.add(ExternalMCPServer(
                id: ExternalMCPServer.makeID(from: name), name: name, command: command,
                args: Self.splitArguments(arguments)))
        } catch { lastError = error.localizedDescription }
        await reload()
    }

    public func remove(_ id: String) async { await manager.remove(id) }
    public func setEnabled(_ id: String, _ on: Bool) async { await manager.setEnabled(id, on) }

    /// Shell-like split: spaces separate words, single or double quotes keep them together.
    public nonisolated static func splitArguments(_ text: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        var started = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch == " " || ch == "\t" {
                if started || !cur.isEmpty { out.append(cur); cur = ""; started = false }
            } else { cur.append(ch) }
        }
        if started || !cur.isEmpty { out.append(cur) }
        return out
    }

    public nonisolated static func statusText(_ s: ExternalServerStatus) -> String {
        switch s {
        case .stopped: "Off"
        case .starting: "Starting…"
        case .running(let n): n == 1 ? "Running · 1 tool" : "Running · \(n) tools"
        case .failed(let why): "Couldn't start: \(why)"
        }
    }
}
