import Testing
import Foundation
import os
@testable import KokoroCore
@testable import StackCore
@testable import StackMCP

@Suite("RemoteAPIProvider requests")
struct RemoteAPIProviderTests {

    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("the base URL we show for OpenAI (…/v1) does not become /v1/v1")
    func openAIBaseWithVersion() {
        let u = RemoteAPIProvider.endpoint(base: url("https://api.openai.com/v1"), path: "chat/completions")
        #expect(u.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("bases without a version segment get /v1 added (Anthropic, local servers)")
    func baseWithoutVersion() {
        #expect(RemoteAPIProvider.endpoint(base: url("https://api.anthropic.com"), path: "messages").absoluteString
                == "https://api.anthropic.com/v1/messages")
        #expect(RemoteAPIProvider.endpoint(base: url("http://localhost:11434"), path: "chat/completions").absoluteString
                == "http://localhost:11434/v1/chat/completions")
        #expect(RemoteAPIProvider.endpoint(base: url("https://api.anthropic.com/"), path: "messages").absoluteString
                == "https://api.anthropic.com/v1/messages")
    }

    @Test("other version numbers and trailing slashes are respected")
    func otherVersions() {
        #expect(RemoteAPIProvider.endpoint(base: url("https://example.com/api/v2"), path: "embeddings").absoluteString
                == "https://example.com/api/v2/embeddings")
        #expect(RemoteAPIProvider.endpoint(base: url("https://openrouter.ai/api/v1/"), path: "chat/completions").absoluteString
                == "https://openrouter.ai/api/v1/chat/completions")
        #expect(RemoteAPIProvider.endpoint(base: url("https://generativelanguage.googleapis.com/v1beta/openai/"), path: "chat/completions").absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    @Test("OpenAI itself gets max_completion_tokens; compatible servers keep max_tokens")
    func tokenLimitKey() {
        #expect(RemoteAPIProvider.tokenLimitKey(for: url("https://api.openai.com/v1")) == "max_completion_tokens")
        #expect(RemoteAPIProvider.tokenLimitKey(for: url("https://openrouter.ai/api/v1")) == "max_tokens")
        #expect(RemoteAPIProvider.tokenLimitKey(for: url("http://localhost:11434/v1")) == "max_tokens")
    }

    @Test("a provider saved without a model name fails clearly instead of sending an empty model")
    func missingModel() async {
        let config = RemoteAPIProvider.Config(
            id: "x", baseURL: url("https://api.openai.com/v1"), modelIdentifier: "  ",
            envVarKey: "X_KEY_UNSET")
        let provider = RemoteAPIProvider(config: config, credentials: CredentialStore())
        var message = ""
        do { for try await _ in await provider.generate(messages: [Message(role: .user, content: "hi")], tools: [], options: GenerationOptions()) {} }
        catch { message = error.localizedDescription }
        #expect(message.contains("No model name"))
        #expect(!(await provider.healthCheck() == .healthy))
    }

    @Test("dropping the stream cancels the in-flight cloud request")
    func cancelStopsRequest() async throws {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [EndlessSSEProtocol.self]
        EndlessSSEProtocol.stopped.withLock { $0 = false }
        let config = RemoteAPIProvider.Config(
            id: "x", baseURL: url("https://example.test/v1"), modelIdentifier: "m", envVarKey: "CANCEL_TEST_KEY")
        setenv("CANCEL_TEST_KEY", "t", 1)
        let creds = CredentialStore(service: "cancel-test-\(UUID().uuidString)")
        await creds.registerEnvVarKey("CANCEL_TEST_KEY", for: "x")
        let provider = RemoteAPIProvider(config: config, credentials: creds, session: URLSession(configuration: c))
        let task = Task {
            for try await _ in await provider.generate(messages: [Message(role: .user, content: "hi")], tools: [], options: GenerationOptions()) { break }
        }
        _ = try? await task.value
        for _ in 0..<50 where !EndlessSSEProtocol.stopped.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(EndlessSSEProtocol.stopped.withLock { $0 })
    }
}

private final class EndlessSSEProtocol: URLProtocol, @unchecked Sendable {
    static let stopped = OSAllocatedUnfairLock(initialState: false)
    private let live = OSAllocatedUnfairLock(initialState: true)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let line = Data("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n".utf8)
        Thread.detachNewThread { [self] in
            while live.withLock({ $0 }) {
                client?.urlProtocol(self, didLoad: line)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    override func stopLoading() { live.withLock { $0 = false }; Self.stopped.withLock { $0 = true } }
}
