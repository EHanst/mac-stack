import Testing
import Foundation
@testable import StackCore

private actor Echo: ModelProvider {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities
    nonisolated let isLocal: Bool
    let failWith: Error?
    init(id: String, capabilities: ProviderCapabilities, isLocal: Bool = true, failWith: Error? = nil) {
        self.id = id; self.capabilities = capabilities; self.isLocal = isLocal; self.failWith = failWith
    }
    func generate(messages: [Message], tools: [ToolDefinition], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let last = messages.last?.content ?? ""
        let failWith = failWith
        return AsyncThrowingStream { c in
            if let failWith { c.finish(throwing: failWith); return }
            c.yield(.token("echo: ")); c.yield(.token(last)); c.yield(.finished(.stop)); c.finish()
        }
    }
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { [Float($0.count), 1] } }
    func healthCheck() async -> ProviderHealth { .healthy }
}

private func makeGateway(policy: RoutingPolicy = .localFirst, extra: [Echo] = []) async -> QueryGateway {
    let registry = ModelRegistry()
    await registry.register(Echo(id: "local:chat", capabilities: [.textGeneration, .streaming]))
    await registry.register(Echo(id: "local:embed", capabilities: [.embedding]))
    for e in extra { await registry.register(e) }
    return QueryGateway(inference: InferenceService(registry: registry, policy: policy))
}

private func expectError(_ expected: QueryError, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("expected \(expected)") }
    catch let e as QueryError { #expect(e == expected) }
    catch { Issue.record("expected QueryError, got \(error)") }
}

@Suite struct QueryGatewayTests {

    @Test func chatCollectsTheAnswerAndReportsTheModel() async throws {
        let gw = await makeGateway()
        let a = try await gw.chat(ChatQuery(messages: [Message(role: .user, content: "hi")], origin: .mcp))
        #expect(a.text == "echo: hi")
        #expect(a.model == "local:chat")
        #expect(a.finish == .stop)
    }

    @Test func chatRefusesEmptyInput() async {
        let gw = await makeGateway()
        await expectError(.invalid(param: "messages", message: "Send at least one non-empty message.")) {
            _ = try await gw.chat(ChatQuery(messages: [Message(role: .user, content: "  ")], origin: .http))
        }
        await expectError(.invalid(param: "messages", message: "Send at least one non-empty message.")) {
            _ = try await gw.chat(ChatQuery(messages: [], origin: .http))
        }
    }

    @Test func maxTokensIsClampedOnce() {
        #expect(ChatQuery.clampedMaxTokens(nil) == 1024)
        #expect(ChatQuery.clampedMaxTokens(0) == 1024)
        #expect(ChatQuery.clampedMaxTokens(-5) == 1024)
        #expect(ChatQuery.clampedMaxTokens(50) == 50)
        #expect(ChatQuery.clampedMaxTokens(1_000_000) == 8192)
    }

    @Test func unknownModelIsATypedError() async {
        let gw = await makeGateway()
        await expectError(.unknownModel("nope")) {
            _ = try await gw.chat(ChatQuery(messages: [Message(role: .user, content: "hi")], model: "nope", origin: .mcp))
        }
    }

    @Test func autoAndDefaultModelMeanRouterChoice() async throws {
        let gw = await makeGateway()
        let a = try await gw.chat(ChatQuery(messages: [Message(role: .user, content: "x")], model: "auto", origin: .mcp))
        #expect(a.model == "local:chat")
    }

    @Test func localOnlyRefusesACloudModelByName() async {
        let cloud = Echo(id: "cloud:big", capabilities: [.textGeneration], isLocal: false)
        let gw = await makeGateway(policy: .localOnly, extra: [cloud])
        await expectError(.blockedByPrivacy) {
            _ = try await gw.chat(ChatQuery(messages: [Message(role: .user, content: "x")], model: "cloud:big", origin: .mcp))
        }
    }

    @Test func noProviderMapsToNoModelAvailable() async {
        let gw = QueryGateway(inference: InferenceService(registry: ModelRegistry()))
        await expectError(.noModelAvailable) {
            _ = try await gw.chat(ChatQuery(messages: [Message(role: .user, content: "x")], origin: .mcp))
        }
    }

    @Test func embedValidatesBatchAndReturnsVectors() async throws {
        let gw = await makeGateway()
        let r = try await gw.embed(EmbedQuery(texts: ["ab", "cde"], origin: .http))
        #expect(r.vectors == [[2, 1], [3, 1]])
        #expect(r.model == "local:embed")
        await expectError(.invalid(param: "input", message: "Send at least one text to embed.")) {
            _ = try await gw.embed(EmbedQuery(texts: [], origin: .http))
        }
        await expectError(.invalid(param: "input", message: "At most \(EmbedQuery.maxTexts) texts per call.")) {
            _ = try await gw.embed(EmbedQuery(texts: Array(repeating: "x", count: EmbedQuery.maxTexts + 1), origin: .http))
        }
    }

    @Test func modelsListsEverythingRegistered() async {
        let gw = await makeGateway()
        let ids = await gw.models().map(\.id)
        #expect(ids.contains("local:chat") && ids.contains("local:embed"))
    }

    // MARK: Error contract

    @Test func existingErrorsMapToTheContract() {
        #expect(QueryError.from(InferenceError.unknownModel("m")) == .unknownModel("m"))
        #expect(QueryError.from(InferenceError.noProvider(.localFirst)) == .noModelAvailable)
        #expect(QueryError.from(InferenceError.notAllowedByPolicy(model: "m", policy: .localOnly)) == .blockedByPrivacy)
        #expect(QueryError.from(EgressError.blockedByPrivacy(host: "h")) == .blockedByPrivacy)
        #expect(QueryError.from(EgressError.budgetExhausted(usedTokens: 2, capTokens: 1)) == .budgetExhausted)
        #expect(QueryError.from(LocalModelError.contextTooLarge(promptTokens: 9, limit: 4)) == .contextTooLarge(promptTokens: 9, limit: 4))
        #expect(QueryError.from(ProviderError.httpError(500)) == .upstream("The cloud provider answered with HTTP 500."))
        #expect(QueryError.from(CancellationError()) == .cancelled)
        #expect(QueryError.from(QueryError.cancelled) == .cancelled)
    }

    @Test func unexpectedErrorsDoNotLeakDetails() {
        struct Secret: Error, LocalizedError { var errorDescription: String? { "/Users/me/secret/path" } }
        let mapped = QueryError.from(Secret())
        #expect(mapped == .internal)
        #expect(!(mapped.errorDescription ?? "").contains("secret"))
    }
}
