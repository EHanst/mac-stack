import Foundation
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

/// The one place that decides whether a tool call may run and what to do with what it returns.
/// The in-app chat and every MCP connection go through it, so the rules can't drift apart.
///
/// - Untrusted output (web, other programs) is fenced and taints the conversation.
/// - While tainted, write and exec calls always ask, and "Always allow" is ignored.
public struct ToolCallGuard: Sendable {
    public let gate: ToolGate?
    public init(gate: ToolGate?) { self.gate = gate }

    /// nil = go ahead; otherwise the message to hand back instead of running the tool.
    public func refusal(
        for handler: any AgentToolHandler, arguments: [String: Value],
        client: ClientIdentity, context: UntrustedContext, alwaysAsk: Bool = false
    ) async -> String? {
        let scope = handler.requiredScope
        guard ApprovalPolicy.needsApproval(scope) else { return nil }
        // The user's own chat runs its tools freely — until outside content is in the conversation.
        if !alwaysAsk, !handler.alwaysRequiresApproval, !context.isTainted { return nil }
        let request = ApprovalRequest(
            client: handler.approvalIdentity ?? client, toolName: handler.toolDefinition.name, scope: scope,
            summary: handler.approvalSummary(arguments: arguments), untrustedSources: context.sources)
        guard let gate, await gate.allows(request) else {
            return "The user didn't allow this action (\(request.summary))."
        }
        return nil
    }

    /// Fences untrusted output and records that the conversation now contains it.
    public func filter(_ content: [Tool.Content], from handler: any AgentToolHandler, context: UntrustedContext) -> [Tool.Content] {
        guard handler.producesUntrustedContent else { return content }
        let name = handler.toolDefinition.name
        context.mark(name)
        return content.map { item in
            if case .text(let text, let annotations, let meta) = item {
                return .text(text: UntrustedContent.wrap(text, source: name), annotations: annotations, _meta: meta)
            }
            return item
        }
    }
}
