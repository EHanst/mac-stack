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
    /// What an outside app must be allowed to do before it may call this tool.
    var requiredScope: ClientScope { get }
    /// One plain-language line for the "Allow?" prompt.
    func approvalSummary(arguments: [String: Value]) -> String
    /// True when the tool's output comes from outside (the web, another program).
    var producesUntrustedContent: Bool { get }
    /// True for tools that run someone else's code (external MCP servers): they ask every time,
    /// even in a clean conversation.
    var alwaysRequiresApproval: Bool { get }
    /// Who the approval prompt names, when it isn't the caller (e.g. the external server).
    var approvalIdentity: ClientIdentity? { get }
}

extension AgentToolHandler {
    public var requiredScope: ClientScope { .toolsRead }
    public var producesUntrustedContent: Bool { false }
    public var alwaysRequiresApproval: Bool { false }
    public var approvalIdentity: ClientIdentity? { nil }
    public func approvalSummary(arguments: [String: Value]) -> String { "Use \(toolDefinition.name)" }
}

// MARK: - Error

public enum AgentToolError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "Missing required argument: \(name)"
        case .invalidArgument(let name, let reason):
            "Invalid \(name): \(reason)"
        }
    }
}
