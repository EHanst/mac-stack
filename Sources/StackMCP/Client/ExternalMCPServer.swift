import Foundation
#if SWIFT_PACKAGE
import StackCore
#endif

/// One MCP server the user added, started as a program on this Mac and spoken to over stdio.
/// Adding it is the user's decision to run that program; each call still asks (see `ExternalMCPTool`).
public struct ExternalMCPServer: Codable, Sendable, Equatable, Identifiable {
    public var id: String          // stable, letters/digits/underscore; prefixes its tool names
    public var name: String        // what the user sees
    public var command: String     // program, looked up on PATH unless it starts with "/"
    public var args: [String]
    public var env: [String: String]
    public var enabled: Bool

    public init(id: String, name: String, command: String, args: [String] = [],
                env: [String: String] = [:], enabled: Bool = true) {
        self.id = id; self.name = name; self.command = command
        self.args = args; self.env = env; self.enabled = enabled
    }

    /// "GitHub tools!" → "github_tools"
    public static func makeID(from name: String) -> String {
        let mapped = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
        let squeezed = mapped.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return squeezed.isEmpty ? "server" : String(squeezed.prefix(24))
    }

    /// Every external tool is exposed as `<server>__<tool>`, so a server can never shadow a built-in
    /// tool such as `write_file`. Characters models or clients may reject are replaced.
    public static func exposedToolName(server: String, tool: String) -> String {
        let cleaned = tool.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_" }.joined()
        return String("\(server)__\(cleaned)".prefix(64))
    }

    public var identity: ClientIdentity {
        ClientIdentity(key: "mcp:\(id)", name: "Tool server “\(name)”")
    }
}

public protocol ExternalServerStore: Sendable {
    func load() throws -> [ExternalMCPServer]
    func save(_ servers: [ExternalMCPServer]) throws
}

/// JSON file, owner-only (environment variables may hold keys), atomic.
public struct FileExternalServerStore: ExternalServerStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/mcp-servers.json")
    }
    public func load() throws -> [ExternalMCPServer] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ExternalMCPServer].self, from: Data(contentsOf: url))
    }
    public func save(_ servers: [ExternalMCPServer]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(servers)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".mcp-servers-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
