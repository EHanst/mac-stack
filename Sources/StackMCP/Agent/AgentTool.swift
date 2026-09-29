import Foundation
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

/// Protocol for tools that the agent can call.
/// `toolDefinition` provides the MCP schema for registration.
/// `execute` performs the actual operation.
public protocol AgentToolHandler: Sendable {
    var toolDefinition: Tool { get }
    func execute(arguments: [String: Value]) async throws -> [Tool.Content]
}

// MARK: - File Reader

public struct FileReaderTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "read_file",
        description: "Read the contents of a file at the given path.",
        inputSchema: .object([
            "path": .object(["type": "string", "description": "Absolute file path"]),
            "startLine": .object(["type": "integer", "description": "First line (1-indexed, optional)"]),
            "endLine": .object(["type": "integer", "description": "Last line (1-indexed, optional)"]),
        ])
    )

    public init() {}

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let path) = arguments["path"] else {
            throw AgentToolError.missingArgument("path")
        }
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let start = arguments["startLine"].flatMap { if case .int(let n) = $0 { return n - 1 } else { return nil } } ?? 0
        let end = arguments["endLine"].flatMap { if case .int(let n) = $0 { return min(n - 1, lines.count - 1) } else { return nil } } ?? (lines.count - 1)
        let slice = (start <= end) ? lines[start...end].joined(separator: "\n") : content
        return [.text(slice)]
    }
}

// MARK: - File Writer

public struct FileWriterTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "write_file",
        description: "Write or overwrite a file at the given path.",
        inputSchema: .object([
            "path": .object(["type": "string"]),
            "content": .object(["type": "string"]),
            "createDirectories": .object(["type": "boolean"]),
        ])
    )

    public init() {}

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let path) = arguments["path"],
              case .string(let content) = arguments["content"] else {
            throw AgentToolError.missingArgument("path or content")
        }
        let url = URL(fileURLWithPath: path)
        if case .bool(true) = arguments["createDirectories"] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        let data = Data(content.utf8)
        try data.write(to: url, options: .atomic)
        return [.text("Wrote \(data.count) bytes to \(url.lastPathComponent)")]
    }
}

// MARK: - Compiler Runner

public struct CompilerRunnerTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "run_build",
        description: "Run a build command in the project workspace.",
        inputSchema: .object([
            "command": .object(["type": "string"]),
            "workingDirectory": .object(["type": "string"]),
            "timeoutSeconds": .object(["type": "integer"]),
        ])
    )

    private let runner: XPCBuildRunner
    public init(runner: XPCBuildRunner) { self.runner = runner }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let command) = arguments["command"],
              case .string(let wd) = arguments["workingDirectory"] else {
            throw AgentToolError.missingArgument("command or workingDirectory")
        }
        let timeout: Duration
        if case .int(let s) = arguments["timeoutSeconds"] { timeout = .seconds(s) }
        else { timeout = .seconds(120) }
        let result = try await runner.run(
            command: command,
            workingDirectory: URL(fileURLWithPath: wd),
            timeout: timeout
        )
        let output = "exit: \(result.exitCode)\n\(result.stdout)\(result.stderr)"
        return [.text(output)]
    }
}

// MARK: - Error

public enum AgentToolError: LocalizedError {
    case missingArgument(String)
    public var errorDescription: String? { "Missing required argument: \(self)" }
}
