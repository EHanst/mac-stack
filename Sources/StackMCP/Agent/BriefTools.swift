import Foundation
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

// Tools that hand the user's briefs to an outside coding tool. Behind the `briefs` permission,
// which a new client does not get. What is returned is the compiled prompt, so secrets are already redacted.

private func text(_ s: String) -> [Tool.Content] { [.text(text: s, annotations: nil, _meta: nil)] }

public struct ListBriefsTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "list_briefs",
        description: "List the user's briefs (prompts they prepared in Kokoro): id, title, target and last edit. Use get_brief with an id to read one.",
        inputSchema: .object(["type": "object", "properties": .object([:])]))
    public var requiredScope: ClientScope { .briefs }
    let provider: @Sendable () async -> [Brief]
    public init(provider: @escaping @Sendable () async -> [Brief]) { self.provider = provider }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let briefs = await provider().sorted { $0.updatedAt > $1.updatedAt }
        guard !briefs.isEmpty else { return text("There are no briefs yet. Create one in Kokoro.") }
        let stamp = ISO8601DateFormatter()
        return text(briefs.map {
            let edited = $0.body != nil ? " · edited" : ""
            return "\($0.id) — \($0.title) (\($0.target.surface.displayName), edited \(stamp.string(from: $0.updatedAt)))\(edited)"
        }.joined(separator: "\n"))
    }
}

public struct GetBriefTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "get_brief",
        description: "Get one brief as a finished prompt, ready to follow. Pass the id from list_briefs.",
        inputSchema: .object([
            "type": "object",
            "properties": .object(["id": .object(["type": "string", "description": "Brief id from list_briefs"])]),
            "required": .array([.string("id")]),
        ]))
    public var requiredScope: ClientScope { .briefs }
    let provider: @Sendable () async -> [Brief]
    public init(provider: @escaping @Sendable () async -> [Brief]) { self.provider = provider }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let id) = arguments["id"], !id.isEmpty else { throw AgentToolError.missingArgument("id") }
        guard let brief = await provider().first(where: { $0.id == id }) else {
            return text("No brief with id \(id). Call list_briefs for the ids.")
        }
        let out = BriefCompiler.compile(brief)
        if out.warnings.contains(where: { $0.code == .emptyInput }) {
            return text("The brief \"\(brief.title)\" is empty, so there is nothing to follow.")
        }
        return text(out.text)
    }
}
