import Foundation
import os

/// OpenAI-compatible adapter for remote hosted models.
/// Covers OpenAI, Anthropic (via compatibility), Ollama, and any endpoint
/// implementing the OpenAI Chat Completions API.
/// New providers need only a Config entry — no code changes.
public actor RemoteAPIProvider: ModelProvider {

    public enum APIStyle: String, Codable, Sendable {
        case openAIChat          // POST /v1/chat/completions
        case anthropicMessages   // POST /v1/messages
        case ollamaGenerate      // POST /api/generate (streaming NDJSON)
    }

    public struct Config: Codable, Sendable {
        public let id: ProviderID
        public let baseURL: URL
        public let modelIdentifier: String
        public let capabilities: ProviderCapabilities
        public let apiStyle: APIStyle
        public let envVarKey: String   // env var name for the token
        public let embeddingModelIdentifier: String?

        public init(
            id: ProviderID,
            baseURL: URL,
            modelIdentifier: String,
            capabilities: ProviderCapabilities = [.textGeneration, .toolUse, .streaming],
            apiStyle: APIStyle = .openAIChat,
            envVarKey: String,
            embeddingModelIdentifier: String? = nil
        ) {
            self.id = id
            self.baseURL = baseURL
            self.modelIdentifier = modelIdentifier
            self.capabilities = capabilities
            self.apiStyle = apiStyle
            self.envVarKey = envVarKey
            self.embeddingModelIdentifier = embeddingModelIdentifier
        }
    }

    public nonisolated let id: ProviderID
    public nonisolated let capabilities: ProviderCapabilities

    private let config: Config
    private let credentials: CredentialStore
    private let session: URLSession
    private let gate: EgressGate?
    private let logger = Logger(subsystem: "com.vibecockpit", category: "RemoteAPIProvider")

    public init(config: Config, credentials: CredentialStore,
                session: URLSession = URLSession(configuration: .default), gate: EgressGate? = nil) {
        self.gate = gate
        self.config = config
        self.credentials = credentials
        self.id = config.id
        self.capabilities = config.capabilities
        self.session = session
    }

    // MARK: Request building (pure, unit-tested)

    /// Provider docs give base URLs both with a version segment (`https://api.openai.com/v1`) and
    /// without one (`https://api.anthropic.com`). Add `v1/` only when the base doesn't have one,
    /// otherwise the default OpenAI URL we show would become `/v1/v1/chat/completions` (404).
    static func endpoint(base: URL, path: String) -> URL {
        // Any version segment in the base (v1, v2, v1beta, …) means the docs' base already has it,
        // e.g. https://generativelanguage.googleapis.com/v1beta/openai/.
        let versioned = base.pathComponents.contains { $0.range(of: #"^v[0-9]+(alpha|beta)?$"#, options: .regularExpression) != nil }
        return base.appendingPathComponent(versioned ? path : "v1/\(path)")
    }

    /// OpenAI's Chat Completions deprecated `max_tokens` for `max_completion_tokens` (gpt-5 and
    /// o-series reject the old name); other OpenAI-compatible servers still expect `max_tokens`.
    static func tokenLimitKey(for base: URL) -> String {
        base.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens"
    }

    // Every request goes through the egress gate first ("Only on this Mac", monthly limit, ledger).
    private func gatedData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let gate, let url = request.url { try await gate.authorize(.cloudInference, url: url, provider: id) }
        return try await session.data(for: request)
    }

    private func gatedBytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        if let gate, let url = request.url { try await gate.authorize(.cloudInference, url: url, provider: id) }
        return try await session.bytes(for: request)
    }

    private func requireModel() throws {
        if config.apiStyle != .ollamaGenerate, config.modelIdentifier.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ProviderError.missingModel
        }
    }

    public func generate(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try requireModel()
                    let token = try await credentials.token(for: config.id)
                    switch config.apiStyle {
                    case .openAIChat:
                        try await streamOpenAI(messages: messages, tools: tools, options: options,
                                               token: token, continuation: continuation)
                    case .anthropicMessages:
                        try await streamAnthropic(messages: messages, tools: tools, options: options,
                                                  token: token, continuation: continuation)
                    case .ollamaGenerate:
                        try await streamOllama(messages: messages, options: options,
                                               continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard capabilities.contains(.embedding),
              let embeddingModel = config.embeddingModelIdentifier else {
            throw ProviderError.capabilityUnavailable(.embedding)
        }
        let token = try await credentials.token(for: config.id)
        var request = URLRequest(url: Self.endpoint(base: config.baseURL, path: "embeddings"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["input": texts, "model": embeddingModel]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await gatedData(request)
        try validate(response: response)
        return try parseEmbeddingResponse(data)
    }

    public func healthCheck() async -> ProviderHealth {
        let token: String
        do {
            token = try await credentials.token(for: config.id)
        } catch {
            return .unavailable("No credential: \(error.localizedDescription)")
        }
        do {
            switch config.apiStyle {
            case .openAIChat:
                try await probeOpenAI(token: token)
            case .anthropicMessages:
                try await probeAnthropic(token: token)
            case .ollamaGenerate:
                try await probeOllama()
            }
            return .healthy
        } catch ProviderError.httpError(let code) {
            return .degraded("HTTP \(code)")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Health checks list models (free) instead of generating text: a "hi" completion on every
    /// status refresh would cost tokens and send a prompt nobody asked for.
    private func probeOpenAI(token: String) async throws {
        try requireModel()
        var request = URLRequest(url: Self.endpoint(base: config.baseURL, path: "models"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (_, response) = try await gatedData(request)
        try validateProbe(response)
    }

    /// Servers that don't implement the model list (404/405) are taken as reachable.
    private func validateProbe(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 405 { return }
        try validate(response: response)
    }

    private func probeAnthropic(token: String) async throws {
        var request = URLRequest(url: Self.endpoint(base: config.baseURL, path: "models"))
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10
        let (_, response) = try await gatedData(request)
        try validateProbe(response)
    }

    private func probeOllama() async throws {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (_, response) = try await gatedData(request)
        try validate(response: response)
    }

    // MARK: - Private streaming implementations

    private func streamOpenAI(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions,
        token: String,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: Self.endpoint(base: config.baseURL, path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": config.modelIdentifier,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            Self.tokenLimitKey(for: config.baseURL): options.maxTokens,
            "temperature": options.temperature,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function",
                                         "function": ["name": $0.name,
                                                      "description": $0.description,
                                                      "parameters": $0.inputSchema.foundationObject]] }
        }
        if !options.stopSequences.isEmpty { body["stop"] = options.stopSequences }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (stream, response) = try await gatedBytes(request)
        try validate(response: response)
        for try await line in stream.lines {
            guard line.hasPrefix("data: "), !line.hasSuffix("[DONE]") else { continue }
            let json = String(line.dropFirst(6))
            if let event = try? parseSSEToken(json) { continuation.yield(event) }
        }
        continuation.yield(.finished(.stop))
    }

    private func streamAnthropic(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions,
        token: String,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: Self.endpoint(base: config.baseURL, path: "messages"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let systemMsg = messages.first(where: { $0.role == .system })?.content ?? ""
        let nonSystem = messages.filter { $0.role != .system }
        let body: [String: Any] = [
            "model": config.modelIdentifier,
            "system": systemMsg,
            "messages": nonSystem.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": options.maxTokens,
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (stream, response) = try await gatedBytes(request)
        try validate(response: response)
        for try await line in stream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type_ = obj["type"] as? String {
                if type_ == "content_block_delta",
                   let delta = obj["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    continuation.yield(.token(text))
                } else if type_ == "message_stop" {
                    continuation.yield(.finished(.stop))
                }
            }
        }
    }

    private func streamOllama(
        messages: [Message],
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.modelIdentifier,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (stream, response) = try await gatedBytes(request)
        try validate(response: response)
        for try await line in stream.lines {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    continuation.yield(.token(content))
                }
                if (obj["done"] as? Bool) == true { continuation.yield(.finished(.stop)) }
            }
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpError(http.statusCode)
        }
    }

    private func parseSSEToken(_ json: String) throws -> GenerationEvent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first else { return nil }
        if let delta = choice["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return .token(content)
        }
        if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
            return .finished(FinishReason(rawValue: finishReason) ?? .stop)
        }
        return nil
    }

    private func parseEmbeddingResponse(_ data: Data) throws -> [[Float]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = obj["data"] as? [[String: Any]] else {
            throw ProviderError.malformedResponse
        }
        return dataArray.compactMap { item -> [Float]? in
            guard let embedding = item["embedding"] as? [Double] else { return nil }
            return embedding.map { Float($0) }
        }
    }
}

public enum ProviderError: LocalizedError {
    case capabilityUnavailable(ProviderCapabilities)
    case httpError(Int)
    case malformedResponse
    case notAvailable(String)
    case missingModel

    public var errorDescription: String? {
        switch self {
        case .capabilityUnavailable: "Provider does not support this capability."
        case .httpError(let code): "HTTP error \(code)."
        case .malformedResponse: "Malformed response from provider."
        case .notAvailable(let reason): "Provider unavailable: \(reason)."
        case .missingModel: "No model name is set for this provider. Add one (for example gpt-4o or claude-sonnet-5-5) in the model settings."
        }
    }
}
