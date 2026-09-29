import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
#if SWIFT_PACKAGE
import StackCore
#endif

public struct APIServerConfiguration: Sendable {
    /// Loopback only. Never `0.0.0.0`.
    public var host = "127.0.0.1"
    public var port: Int
    /// Web origins allowed to call the API (normally none: only non-browser apps do).
    public var allowedOrigins: Set<String> = []
    /// Largest request body accepted.
    public var maxBodyBytes = 8 << 20
    /// How often a keep-alive comment is sent while a long prompt is still being processed.
    public var keepAlive: Duration = .seconds(10)

    public static let defaultPort = 11_500

    public init(port: Int = APIServerConfiguration.defaultPort) { self.port = port }
}

/// The OpenAI-compatible HTTP API for other apps on this Mac. Off unless the user turns it on;
/// bound to 127.0.0.1; every request needs a per-app bearer token with the right scope.
public struct StackAPIServer: Sendable {

    let inference: InferenceService
    let clients: ClientRegistry
    let configuration: APIServerConfiguration
    let logger = Logger(label: "vibecockpit.api")

    public init(inference: InferenceService, clients: ClientRegistry, configuration: APIServerConfiguration = .init()) {
        self.inference = inference
        self.clients = clients
        self.configuration = configuration
    }

    // MARK: Application

    func router() -> Hummingbird.Router<APIRequestContext> {
        let router = Hummingbird.Router(context: APIRequestContext.self)
        router.add(middleware: ErrorMiddleware())
        router.add(middleware: LoopbackGuard(allowedOrigins: configuration.allowedOrigins))
        router.add(middleware: AuthMiddleware(clients: clients))

        router.get("healthz") { _, _ in
            Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: #"{"status":"ok"}"#)))
        }
        router.get("v1/models") { _, context in try await self.models(context: context) }
        router.post("v1/chat/completions") { request, context in try await self.chat(request, context: context) }
        router.post("v1/embeddings") { request, context in try await self.embeddings(request, context: context) }
        // Unmatched paths raise HTTPError(.notFound), which ErrorMiddleware turns into an OpenAI-style 404.
        return router
    }

    public func makeApplication(onListening: @escaping @Sendable (Int) async -> Void = { _ in }) -> some ApplicationProtocol {
        Application(
            router: router(),
            configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: "VibeCockpit"),
            onServerRunning: { channel in await onListening(channel.localAddress?.port ?? 0) },
            logger: logger)
    }

    /// Runs until cancelled. `onListening` reports the port once the socket is bound (useful with port 0).
    /// Signal handling is left to the host app.
    public func run(onListening: @escaping @Sendable (Int) async -> Void = { _ in }) async throws {
        try await makeApplication(onListening: onListening).runService(gracefulShutdownSignals: [])
    }

    // MARK: Helpers

    private static func json(_ body: String, status: HTTPResponse.Status = .ok) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    private func body<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        let buffer = try await request.body.collect(upTo: configuration.maxBodyBytes)
        return try JSONDecoder().decode(T.self, from: Data(buffer.readableBytesView))
    }

    static func pin(for requested: String?) -> ProviderID? { InferenceService.pin(for: requested) }

    // MARK: /v1/models

    private func models(context: APIRequestContext) async throws -> Response {
        _ = try context.require(.models)
        let entries = await inference.availableModels().map {
            OpenAIModelList.Entry(id: $0.id, ownedBy: $0.isLocal ? "this-mac" : "cloud")
        }
        return Self.json(OpenAIModelList.json(entries))
    }

    // MARK: /v1/embeddings

    private func embeddings(_ request: Request, context: APIRequestContext) async throws -> Response {
        _ = try context.require(.embeddings)
        let req = try await body(OpenAIEmbeddingsRequest.self, from: request)
        let texts = try req.texts()
        let result = try await inference.embed(texts, pin: Self.pin(for: req.model))
        let tokens = InferenceService.estimateTokens(texts.map { Message(role: .user, content: $0) })
        return Self.json(OpenAIEmbeddingsResponse.json(vectors: result.vectors, model: result.provider, promptTokens: tokens))
    }

    // MARK: /v1/chat/completions

    private func chat(_ request: Request, context: APIRequestContext) async throws -> Response {
        _ = try context.require(.chat)
        let gen = try await body(OpenAIChatRequest.self, from: request).toGeneration()
        let pin = Self.pin(for: gen.requestedModel)

        // The local model doesn't render tool definitions yet; refuse rather than silently ignore them.
        if gen.hasTools, pin == nil || pin?.hasPrefix("local:") == true {
            throw OpenAIError.invalidRequest(
                "Tool calling isn't supported by the local model yet. Remove 'tools', or name a cloud model in 'model'.",
                param: "tools", code: "tools_unsupported")
        }

        let events = try await inference.generate(
            messages: gen.messages, tools: [], options: gen.options, priority: .api, pin: pin)
        let builder = ChatCompletionBuilder(model: gen.requestedModel ?? "vibecockpit")
        let promptEstimate = max(1, InferenceService.estimateTokens(gen.messages))

        if gen.stream {
            return streamingResponse(events: events, builder: builder, includeUsage: gen.includeUsage, promptEstimate: promptEstimate)
        }

        // Non-streaming: collect the whole answer.
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
        let u = usage ?? GenerationUsage(promptTokens: promptEstimate, completionTokens: max(1, text.count / 3))
        return Self.json(builder.response(text: text, finish: finish, usage: u))
    }

    // MARK: Streaming

    private enum Item: Sendable {
        case event(GenerationEvent)
        case keepAlive
        case failed(OpenAIError)
        case end
    }

    private func streamingResponse(
        events: AsyncThrowingStream<GenerationEvent, Error>, builder: ChatCompletionBuilder, includeUsage: Bool, promptEstimate: Int
    ) -> Response {
        let keepAlive = configuration.keepAlive
        let headers: HTTPFields = [
            .contentType: "text/event-stream",
            .cacheControl: "no-cache",
            HTTPField.Name("X-Accel-Buffering")!: "no",
        ]
        return Response(status: .ok, headers: headers, body: .init { writer in
            func send(_ s: String) async throws { try await writer.write(ByteBuffer(string: s)) }

            // One task reads the model, one ticks keep-alives; this closure writes what they produce.
            // If the client goes away, `send` throws, both tasks are cancelled, and cancelling the
            // producer terminates the generation stream, which frees the GPU.
            let (items, sink) = AsyncStream.makeStream(of: Item.self)
            let producer = Task {
                do {
                    for try await e in events { sink.yield(.event(e)) }
                    sink.yield(.end)
                } catch is CancellationError {
                    sink.yield(.end)
                } catch {
                    sink.yield(.failed(OpenAIError.from(error)))
                }
                sink.finish()
            }
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: keepAlive)
                    if Task.isCancelled { break }
                    sink.yield(.keepAlive)
                }
            }
            defer { producer.cancel(); ticker.cancel() }

            try await send(builder.streamStart())
            var usage: GenerationUsage?
            var finish = FinishReason.stop
            var text = ""
            for await item in items {
                switch item {
                case .keepAlive:
                    try await send(": keep-alive\n\n")
                case .event(.token(let t)):
                    text += t
                    try await send(builder.streamDelta(t))
                case .event(.usage(let u)): usage = u
                case .event(.finished(let f)): finish = f
                case .event(.toolCall): break
                case .failed(let error):
                    try await send(builder.streamError(error))
                    try await writer.finish(nil)
                    return
                case .end:
                    try await send(builder.streamEnd(finish: finish, usage: usage ?? GenerationUsage(promptTokens: promptEstimate, completionTokens: max(1, text.count / 3)), includeUsage: includeUsage))
                    try await writer.finish(nil)
                    return
                }
            }
            try await writer.finish(nil)
        })
    }
}
