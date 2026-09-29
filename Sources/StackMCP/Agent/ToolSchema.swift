import Foundation
import MCP

extension Tool {
    /// Several tools were written with a bare property map (`{"path": {...}}`) as their input
    /// schema. Clients and models expect JSON Schema (`{"type":"object","properties":{…}}`), so
    /// anything without a `type` is wrapped. Already-valid schemas are returned unchanged.
    public var withValidSchema: Tool {
        guard case .object(let obj) = inputSchema, obj["type"] == nil else { return self }
        let properties: [String: Value]
        if case .object(let p)? = obj["properties"] { properties = p } else { properties = obj }
        return Tool(name: name, title: title, description: description,
                    inputSchema: .object(["type": "object", "properties": .object(properties)]),
                    annotations: annotations, _meta: _meta)
    }
}
