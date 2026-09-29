import Foundation
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

// Tools that expose the model itself (not the workspace) to MCP clients. They work with or
// without a project open, and go through InferenceService like every other request, so the
// routing policy ("Only on this Mac"), the GPU queue and model pinning all apply.

private func text(_ s: String) -> [Tool.Content] { [.text(text: s, annotations: nil, _meta: nil)] }

private func objectSchema(_ properties: [String: Value], required: [String] = []) -> Value {
    var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
}

// MARK: - list_models

public struct ListModelsTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "list_models",
        description: "List the AI models VibeCockpit can use right now, and whether each runs on this Mac or in the cloud.",
        inputSchema: objectSchema([:]))
    public var requiredScope: ClientScope { .models }
    let inference: InferenceService
    public init(inference: InferenceService) { self.inference = inference }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let models = await inference.availableModels()
        guard !models.isEmpty else { return text("No models are set up yet. Open VibeCockpit to add one.") }
        let lines = models.map { m -> String in
            let health: String
            switch m.health {
            case .healthy: health = "ready"
            case .degraded(let why): health = "loading (\(why))"
            case .unavailable(let why): health = "unavailable (\(why))"
            }
            return "\(m.id) — \(m.isLocal ? "on this Mac" : "cloud"), \(health)"
        }
        return text(lines.joined(separator: "\n"))
    }
}

// MARK: - chat

public struct ChatTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "chat",
        description: "Ask the model running in VibeCockpit a question and get its answer. Runs on this Mac unless the user allowed the cloud.",
        inputSchema: objectSchema([
            "prompt": .object(["type": "string", "description": "What to ask"]),
            "system": .object(["type": "string", "description": "Optional instructions for how to answer"]),
            "model": .object(["type": "string", "description": "Optional model id from list_models; default lets VibeCockpit choose"]),
            "maxTokens": .object(["type": "integer", "description": "Longest answer, in tokens (default 1024)"]),
        ], required: ["prompt"]))
    public var requiredScope: ClientScope { .chat }
    let inference: InferenceService
    public init(inference: InferenceService) { self.inference = inference }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let prompt) = arguments["prompt"], !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        var messages: [ModelMessage] = []
        if case .string(let system) = arguments["system"], !system.isEmpty {
            messages.append(ModelMessage(role: .system, content: system))
        }
        messages.append(ModelMessage(role: .user, content: prompt))
        var requested: String?
        if case .string(let m) = arguments["model"] { requested = m }
        var maxTokens = 1024
        if case .int(let n) = arguments["maxTokens"], n > 0 { maxTokens = min(n, 8192) }

        let events = try await inference.generate(
            messages: messages, tools: [], options: GenerationOptions(maxTokens: maxTokens),
            priority: .api, pin: InferenceService.pin(for: requested))
        var answer = ""
        for try await event in events { if case .token(let t) = event { answer += t } }
        return text(answer)
    }
}

// MARK: - embed

public struct EmbedTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "embed",
        description: "Turn text into embedding vectors (for search or similarity). Returns JSON: {\"model\": …, \"embeddings\": [[…]]}.",
        inputSchema: objectSchema([
            "texts": .object(["type": "array", "items": .object(["type": "string"]), "description": "Texts to embed"]),
            "model": .object(["type": "string", "description": "Optional embedding model id"]),
        ], required: ["texts"]))
    public var requiredScope: ClientScope { .embeddings }
    let inference: InferenceService
    public init(inference: InferenceService) { self.inference = inference }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .array(let items) = arguments["texts"] else { throw AgentToolError.missingArgument("texts") }
        let texts = items.compactMap { item -> String? in if case .string(let s) = item { return s } else { return nil } }
        guard !texts.isEmpty else { throw AgentToolError.missingArgument("texts") }
        var requested: String?
        if case .string(let m) = arguments["model"] { requested = m }
        let result = try await inference.embed(texts, pin: InferenceService.pin(for: requested))
        let body: [String: Any] = ["model": result.provider, "embeddings": result.vectors]
        let data = try JSONSerialization.data(withJSONObject: body)
        return text(String(decoding: data, as: UTF8.self))
    }
}
