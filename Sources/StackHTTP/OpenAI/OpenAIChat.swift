import Foundation
import StackCore

/// StackCore's chat message (the OpenAI request type has its own nested `Message`).
private typealias CoreMessage = StackCore.Message

// OpenAI Chat Completions request/response types and their mapping to StackCore's own types.
// No HTTP framework is imported here, so all of this is unit-tested without a server.

// MARK: - Request

public struct OpenAIChatRequest: Decodable, Sendable {

    public enum Content: Decodable, Sendable, Equatable {
        case text(String)
        case parts([Part])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) }
            else { self = .parts(try c.decode([Part].self)) }
        }
    }

    public struct Part: Decodable, Sendable, Equatable {
        public let type: String
        public let text: String?
    }

    public struct Message: Decodable, Sendable {
        public let role: String
        public let content: Content?
        public let toolCallId: String?
        enum CodingKeys: String, CodingKey { case role, content, toolCallId = "tool_call_id" }
    }

    public struct StreamOptions: Decodable, Sendable {
        public let includeUsage: Bool?
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    /// `stop` may be one string or a list.
    public enum Stop: Decodable, Sendable, Equatable {
        case one(String), many([String])
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
        }
        var list: [String] { switch self { case .one(let s): [s]; case .many(let m): m } }
    }

    public let model: String?
    public let messages: [Message]?
    public let stream: Bool?
    public let streamOptions: StreamOptions?
    public let maxTokens: Int?
    public let maxCompletionTokens: Int?
    public let temperature: Double?
    public let topP: Double?
    public let topK: Int?
    public let presencePenalty: Double?
    public let stop: Stop?
    public let n: Int?
    public let tools: [JSONValue]?
    public let functions: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop, n, tools, functions
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case topP = "top_p", topK = "top_k"
        case presencePenalty = "presence_penalty"
    }
}

/// A chat request after validation, in StackCore's terms.
public struct ChatGeneration: Sendable {
    public let requestedModel: String?
    public let messages: [StackCore.Message]
    public let options: GenerationOptions
    public let stream: Bool
    public let includeUsage: Bool
    /// Tool definitions the caller supplied; the server refuses them for local models.
    public let hasTools: Bool
}

extension OpenAIChatRequest {

    /// Largest reply a client may ask for.
    public static let maxAllowedTokens = 32_768

    public func toGeneration() throws -> ChatGeneration {
        guard let raw = messages, !raw.isEmpty else {
            throw OpenAIError.invalidRequest("'messages' must be a non-empty array.", param: "messages")
        }
        if let n, n != 1 {
            throw OpenAIError.invalidRequest("Only n = 1 is supported.", param: "n")
        }
        var converted: [CoreMessage] = []
        for (index, m) in raw.enumerated() {
            let role: CoreMessage.Role
            switch m.role {
            case "system", "developer": role = .system
            case "user": role = .user
            case "assistant": role = .assistant
            case "tool": role = .tool
            default:
                throw OpenAIError.invalidRequest("Unsupported role '\(m.role)'.", param: "messages[\(index)].role")
            }
            let text: String
            switch m.content {
            case .none: text = ""
            case .some(.text(let s)): text = s
            case .some(.parts(let parts)):
                var pieces: [String] = []
                for p in parts {
                    guard p.type == "text", let t = p.text else {
                        throw OpenAIError.invalidRequest(
                            "Content of type '\(p.type)' isn't supported: this model only reads text.",
                            param: "messages[\(index)].content", code: "unsupported_content")
                    }
                    pieces.append(t)
                }
                text = pieces.joined(separator: "\n")
            }
            converted.append(CoreMessage(role: role, content: text, toolCallID: m.toolCallId))
        }
        guard converted.contains(where: { $0.role == .user || $0.role == .tool }) else {
            throw OpenAIError.invalidRequest("'messages' needs at least one user message.", param: "messages")
        }

        let requested = maxCompletionTokens ?? maxTokens
        if let requested, requested < 1 {
            throw OpenAIError.invalidRequest("max tokens must be at least 1.", param: "max_tokens")
        }
        var options = GenerationOptions(
            maxTokens: min(requested ?? GenerationOptions.defaultMaxTokens, Self.maxAllowedTokens),
            temperature: temperature ?? 0)
        options.stopSequences = Array((stop?.list ?? []).filter { !$0.isEmpty }.prefix(4))
        options.sampling = samplingOverride()

        return ChatGeneration(
            requestedModel: model, messages: converted, options: options,
            stream: stream ?? false, includeUsage: streamOptions?.includeUsage ?? false,
            hasTools: !(tools ?? []).isEmpty || !(functions ?? []).isEmpty)
    }

    /// Any sampling field the caller sets overrides the model card's defaults; the rest keep them.
    /// `temperature: 0` means greedy. Nothing set ⇒ nil (the provider's default).
    func samplingOverride() -> SamplingParameters? {
        if temperature == nil && topP == nil && topK == nil && presencePenalty == nil { return nil }
        if let t = temperature, t <= 0 { return .greedy }
        let base = SamplingParameters.bonsaiInstruct
        return SamplingParameters(
            temperature: temperature ?? base.temperature,
            topK: topK ?? base.topK,
            topP: topP ?? base.topP,
            presencePenalty: presencePenalty ?? base.presencePenalty)
    }
}

// MARK: - Response encoding

enum OpenAIJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

public enum OpenAIFinish {
    public static func string(_ reason: FinishReason) -> String {
        switch reason {
        case .stop, .error: "stop"
        case .length: "length"
        case .toolUse: "tool_calls"
        }
    }
}

struct OpenAIUsageBody: Encodable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
    init(_ u: GenerationUsage) {
        prompt_tokens = u.promptTokens; completion_tokens = u.completionTokens; total_tokens = u.totalTokens
    }
}

/// Builds a complete (non-streaming) response.
public struct ChatCompletionBuilder: Sendable {
    public let id: String
    public let created: Int
    public let model: String

    public init(model: String, id: String = "chatcmpl-" + UUID().uuidString.lowercased().prefix(24), created: Date = Date()) {
        self.id = String(id)
        self.created = Int(created.timeIntervalSince1970)
        self.model = model
    }

    public func response(text: String, finish: FinishReason, usage: GenerationUsage) -> String {
        struct Body: Encodable {
            struct Choice: Encodable {
                struct Msg: Encodable { let role = "assistant"; let content: String }
                let index = 0; let message: Msg; let finish_reason: String
            }
            let id: String; let object = "chat.completion"; let created: Int; let model: String
            let choices: [Choice]; let usage: OpenAIUsageBody
        }
        return OpenAIJSON.encode(Body(
            id: id, created: created, model: model,
            choices: [.init(message: .init(content: text), finish_reason: OpenAIFinish.string(finish))],
            usage: OpenAIUsageBody(usage)))
    }

    // MARK: Streaming (server-sent events)

    private struct Chunk: Encodable {
        struct Choice: Encodable {
            struct Delta: Encodable { let role: String?; let content: String? }
            let index = 0; let delta: Delta; let finish_reason: String?
        }
        let id: String; let object = "chat.completion.chunk"; let created: Int; let model: String
        let choices: [Choice]; let usage: OpenAIUsageBody?
        // OpenAI sends `"usage": null` on content chunks when include_usage is on; omit otherwise.
    }

    private func sse(_ chunk: Chunk) -> String { "data: \(OpenAIJSON.encode(chunk))\n\n" }

    /// First chunk: announces the assistant role.
    public func streamStart() -> String {
        sse(Chunk(id: id, created: created, model: model,
                  choices: [.init(delta: .init(role: "assistant", content: ""), finish_reason: nil)], usage: nil))
    }

    public func streamDelta(_ text: String) -> String {
        sse(Chunk(id: id, created: created, model: model,
                  choices: [.init(delta: .init(role: nil, content: text), finish_reason: nil)], usage: nil))
    }

    /// Final chunk(s): the finish reason, optionally a usage chunk, then `[DONE]`.
    public func streamEnd(finish: FinishReason, usage: GenerationUsage?, includeUsage: Bool) -> String {
        var out = sse(Chunk(id: id, created: created, model: model,
                            choices: [.init(delta: .init(role: nil, content: nil), finish_reason: OpenAIFinish.string(finish))],
                            usage: nil))
        if includeUsage, let usage {
            out += sse(Chunk(id: id, created: created, model: model, choices: [], usage: OpenAIUsageBody(usage)))
        }
        return out + "data: [DONE]\n\n"
    }

    /// An error that happens after streaming started can only be delivered in-band.
    public func streamError(_ error: OpenAIError) -> String {
        "data: \(String(data: error.jsonBody, encoding: .utf8) ?? "{}")\n\ndata: [DONE]\n\n"
    }
}
