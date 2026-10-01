import Foundation

/// Where a query came from. Both use the API priority today; kept so the scheduler and logs can tell them apart.
public enum QueryOrigin: Sendable, Equatable { case mcp, http }

public struct ChatQuery: Sendable {
    public var messages: [Message]
    /// Model id, or nil / "auto" / "default" to let the router choose.
    public var model: String?
    public var maxTokens: Int?
    public var origin: QueryOrigin

    public init(messages: [Message], model: String? = nil, maxTokens: Int? = nil, origin: QueryOrigin) {
        self.messages = messages; self.model = model; self.maxTokens = maxTokens; self.origin = origin
    }

    public static let defaultMaxTokens = 1024
    public static let maxAllowedTokens = 8192
    public static let maxMessages = 100
    public static let maxTotalCharacters = 500_000

    /// One rule for every endpoint: missing or non-positive means the default; the top is capped.
    public static func clampedMaxTokens(_ requested: Int?) -> Int {
        guard let n = requested, n > 0 else { return defaultMaxTokens }
        return min(n, maxAllowedTokens)
    }
}

public struct ChatAnswer: Sendable, Equatable {
    public let text: String
    /// The provider that produced the answer (after any fallback).
    public let model: ProviderID?
    public let finish: FinishReason
    public let usage: GenerationUsage?
}

public struct EmbedQuery: Sendable {
    public var texts: [String]
    public var model: String?
    public var origin: QueryOrigin
    public static let maxTexts = 256
    public static let maxTextLength = 32_000
    public init(texts: [String], model: String? = nil, origin: QueryOrigin) {
        self.texts = texts; self.model = model; self.origin = origin
    }
}

public struct EmbedAnswer: Sendable, Equatable {
    public let vectors: [[Float]]
    public let model: ProviderID
}

/// The one error `QueryGateway` throws, whatever went wrong underneath. Endpoints translate these
/// to their own wire format; nothing below the gateway needs to be known by them.
public enum QueryError: LocalizedError, Sendable, Equatable {
    case invalid(param: String, message: String)
    case unknownModel(String)
    case blockedByPrivacy
    case budgetExhausted
    case noModelAvailable
    case contextTooLarge(promptTokens: Int, limit: Int)
    case upstream(String)
    case cancelled
    case `internal`

    public var errorDescription: String? {
        switch self {
        case .invalid(_, let m): m
        case .unknownModel(let id): "There is no model called '\(id)'."
        case .blockedByPrivacy: "That would send data off this Mac, which the current privacy setting doesn't allow."
        case .budgetExhausted: "The monthly cloud limit has been reached."
        case .noModelAvailable: "No model is available under the current privacy setting. Set one up in Kokoro."
        case .contextTooLarge(let p, let l): "The prompt is too long for the local model (\(p) tokens, limit \(l))."
        case .upstream(let m): m
        case .cancelled: "The request was cancelled."
        case .internal: "Something went wrong inside Kokoro while handling this request."
        }
    }

    /// Translate anything thrown below the gateway. Unrecognised errors are hidden behind `.internal`
    /// so paths and internals never reach a client.
    public static func from(_ error: Error) -> QueryError {
        switch error {
        case let e as QueryError: return e
        case is CancellationError: return .cancelled
        case let e as InferenceError:
            switch e {
            case .unknownModel(let id): return .unknownModel(id)
            case .notAllowedByPolicy: return .blockedByPrivacy
            case .noProvider: return .noModelAvailable
            }
        case let e as EgressError:
            switch e {
            case .blockedByPrivacy: return .blockedByPrivacy
            case .budgetExhausted: return .budgetExhausted
            }
        case let e as LocalModelError:
            if case .contextTooLarge(let p, let l) = e { return .contextTooLarge(promptTokens: p, limit: l) }
            return .internal
        case let e as ProviderError:
            if case .httpError(let code) = e { return .upstream("The cloud provider answered with HTTP \(code).") }
            return .upstream(e.localizedDescription)
        default: return .internal
        }
    }
}

/// Every endpoint (MCP tools, the local HTTP API) sends its model queries here. The gateway
/// validates and limits them once, routes them through `InferenceService` (which asks `Router`
/// under the current privacy policy, schedules the GPU and falls back before first output),
/// and reports failures only as `QueryError`. In-process only: no sockets between components.
public actor QueryGateway {
    private let inference: InferenceService

    public init(inference: InferenceService) { self.inference = inference }

    public func models() async -> [InferenceService.ModelListing] { await inference.availableModels() }

    public func chat(_ query: ChatQuery) async throws -> ChatAnswer {
        guard query.messages.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw QueryError.invalid(param: "messages", message: "Send at least one non-empty message.")
        }
        guard query.messages.count <= ChatQuery.maxMessages else {
            throw QueryError.invalid(param: "messages", message: "At most \(ChatQuery.maxMessages) messages per call.")
        }
        let totalChars = query.messages.reduce(0) { $0 + $1.content.count }
        guard totalChars <= ChatQuery.maxTotalCharacters else {
            throw QueryError.invalid(param: "messages", message: "Total messages content exceeds maximum length (\(ChatQuery.maxTotalCharacters) characters).")
        }
        let routed = RouteBox()
        do {
            let events = try await inference.generate(
                messages: query.messages, tools: [],
                options: GenerationOptions(maxTokens: ChatQuery.clampedMaxTokens(query.maxTokens)),
                priority: .api, pin: InferenceService.pin(for: query.model),
                onRoute: { routed.record($0) })
            var text = ""
            var finish = FinishReason.stop
            var usage: GenerationUsage?
            for try await event in events {
                switch event {
                case .token(let t): text += t
                case .usage(let u): usage = u
                case .finished(let f): finish = f
                case .toolCall: break
                }
            }
            return ChatAnswer(text: text, model: routed.provider, finish: finish, usage: usage)
        } catch {
            throw QueryError.from(error)
        }
    }

    public func embed(_ query: EmbedQuery) async throws -> EmbedAnswer {
        guard !query.texts.isEmpty else { throw QueryError.invalid(param: "input", message: "Send at least one text to embed.") }
        guard query.texts.count <= EmbedQuery.maxTexts else {
            throw QueryError.invalid(param: "input", message: "At most \(EmbedQuery.maxTexts) texts per call.")
        }
        guard query.texts.allSatisfy({ $0.count <= EmbedQuery.maxTextLength }) else {
            throw QueryError.invalid(param: "input", message: "Individual text exceeds maximum length (\(EmbedQuery.maxTextLength) characters).")
        }
        do {
            let r = try await inference.embed(query.texts, pin: InferenceService.pin(for: query.model))
            return EmbedAnswer(vectors: r.vectors, model: r.provider)
        } catch {
            throw QueryError.from(error)
        }
    }
}

/// Remembers which provider ended up serving a request (the last `using`/`fellBack` notice).
private final class RouteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: ProviderID?
    var provider: ProviderID? { lock.withLock { id } }
    func record(_ notice: RouteNotice) {
        lock.withLock {
            switch notice.kind {
            case .using(let p): id = p
            case .fellBack(_, let to, _): id = to
            }
        }
    }
}
