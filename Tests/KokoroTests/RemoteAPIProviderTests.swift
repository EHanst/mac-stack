import Testing
import Foundation
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
}
