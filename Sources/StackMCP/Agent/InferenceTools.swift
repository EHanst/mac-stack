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
        description: "List the AI models Kokoro can use right now, and whether each runs on this Mac or in the cloud.",
        inputSchema: objectSchema([:]))
    public var requiredScope: ClientScope { .models }
    let gateway: QueryGateway
    public init(gateway: QueryGateway) { self.gateway = gateway }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let models = await gateway.models()
        guard !models.isEmpty else { return text("No models are set up yet. Open Kokoro to add one.") }
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
        description: "Ask the model running in Kokoro a question and get its answer. Runs on this Mac unless the user allowed the cloud.",
        inputSchema: objectSchema([
            "prompt": .object(["type": "string", "description": "What to ask"]),
            "system": .object(["type": "string", "description": "Optional instructions for how to answer"]),
            "model": .object(["type": "string", "description": "Optional model id from list_models; default lets Kokoro choose"]),
            "maxTokens": .object(["type": "integer", "description": "Longest answer, in tokens (default 1024)"]),
        ], required: ["prompt"]))
    public var requiredScope: ClientScope { .chat }
    let gateway: QueryGateway
    public init(gateway: QueryGateway) { self.gateway = gateway }

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
        var maxTokens: Int?
        if case .int(let n) = arguments["maxTokens"] { maxTokens = n }

        let answer = try await gateway.chat(ChatQuery(messages: messages, model: requested, maxTokens: maxTokens, origin: .mcp))
        return text(answer.text)
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
    let gateway: QueryGateway
    public init(gateway: QueryGateway) { self.gateway = gateway }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .array(let items) = arguments["texts"] else { throw AgentToolError.missingArgument("texts") }
        let texts = items.compactMap { item -> String? in if case .string(let s) = item { return s } else { return nil } }
        var requested: String?
        if case .string(let m) = arguments["model"] { requested = m }
        let result = try await gateway.embed(EmbedQuery(texts: texts, model: requested, origin: .mcp))
        let body: [String: Any] = ["model": result.model, "embeddings": result.vectors]
        let data = try JSONSerialization.data(withJSONObject: body)
        return text(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - optimize_prompt

public struct OptimizePromptTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "optimize_prompt",
        description: "Rewrite a prompt so an AI model can act on it better, keeping every code block, path, quoted string and number exactly. Returns the improved prompt (or the original, with the reason, if the rewrite wasn't trustworthy).",
        inputSchema: objectSchema([
            "prompt": .object(["type": "string", "description": "The prompt to improve"]),
            "mode": .object(["type": "string", "enum": .array(["improve", "expand", "adapt"]),
                             "description": "improve (default): clearer, same length. expand: turn it into a detailed specification. adapt: restructure for the target model"]),
            "target": .object(["type": "string", "description": "Optional: the model the prompt is for, e.g. \"claude\" or \"gpt-5\", so the wording suits it"]),
            "model": .object(["type": "string", "description": "Optional model id from list_models to do the rewriting"]),
        ], required: ["prompt"]))
    public var requiredScope: ClientScope { .chat }
    let inference: InferenceService
    public init(inference: InferenceService) { self.inference = inference }

    static func mode(from arguments: [String: Value]) throws -> OptimizeMode {
        guard case .string(let m) = arguments["mode"] else { return .improve }
        switch m {
        case "improve": return .improve
        case "expand": return .expand
        case "adapt": return .adapt
        default: throw AgentToolError.invalidArgument("mode", "must be improve, expand, or adapt")
        }
    }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let prompt) = arguments["prompt"], !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        let mode = try Self.mode(from: arguments)
        var target: String?
        if case .string(let t) = arguments["target"] { target = t }
        var requested: String?
        if case .string(let m) = arguments["model"] { requested = m }
        let context = OptimizeContext(
            profile: .profile(forProviderID: target), pin: InferenceService.pin(for: requested), priority: .api)
        var result: Optimization?
        for try await event in PromptOptimizer(inference: inference).optimize(draft: prompt, context: context, mode: mode) {
            if case .finished(let o) = event { result = o }
        }
        guard let result else { return text("The model returned nothing.") }
        if let rejection = result.rejection { return text("\(result.original)\n\n[not changed: \(rejection.reason)]") }
        if !result.questions.isEmpty && !result.didChange {
            return text("\(result.original)\n\n[needs more detail: " + result.questions.joined(separator: " ") + "]")
        }
        return text(result.improved)
    }
}
