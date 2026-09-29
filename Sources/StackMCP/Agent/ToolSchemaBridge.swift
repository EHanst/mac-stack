import Foundation
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

/// Bridges MCP tool schemas to the protocol-neutral `ToolDefinition` used by model providers.
extension JSONValue {
    public init(_ value: Value) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .int(let v): self = .int(v)
        case .double(let v): self = .double(v)
        case .string(let v): self = .string(v)
        case .data(_, let d): self = .string(d.base64EncodedString())
        case .array(let v): self = .array(v.map(JSONValue.init))
        case .object(let v): self = .object(v.mapValues(JSONValue.init))
        }
    }
}

extension ToolDefinition {
    public init(_ tool: Tool) {
        self.init(name: tool.name, description: tool.description ?? "", inputSchema: JSONValue(tool.inputSchema))
    }
}
