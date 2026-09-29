import XCTest
@testable import StackCore

final class CloudPresetTests: XCTestCase {
    func testPresetsAreWellFormed() {
        XCTAssertEqual(CloudPreset.all.map(\.id), ["openai", "anthropic", "openrouter", "ollama"])
        for p in CloudPreset.all {
            XCTAssertNotNil(p.baseURL.host, p.id)
            XCTAssertEqual(Set(CloudPreset.all.map(\.id)).count, CloudPreset.all.count)
        }
    }

    func testEndpointsResolveWithoutDoubledVersion() {
        let paths = Dictionary(uniqueKeysWithValues: CloudPreset.all.map {
            ($0.id, RemoteAPIProvider.endpoint(base: $0.baseURL, path: $0.apiStyle == .anthropicMessages ? "messages" : "chat/completions").absoluteString)
        })
        XCTAssertEqual(paths["openai"], "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(paths["anthropic"], "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(paths["openrouter"], "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(paths["ollama"], "http://localhost:11434/v1/chat/completions")
    }

    func testOnlyOllamaNeedsNoKeyAndConfigCarriesModel() {
        XCTAssertEqual(CloudPreset.all.filter { !$0.keyRequired }.map(\.id), ["ollama"])
        let c = CloudPreset.preset(id: "anthropic")!.config(model: "claude-sonnet-5-5")
        XCTAssertEqual(c.apiStyle, .anthropicMessages)
        XCTAssertEqual(c.modelIdentifier, "claude-sonnet-5-5")
    }
}

final class RemoteConfigPersistenceTests: XCTestCase {
    func testSavedProviderSurvivesReloadAndReplacesSameId() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("providers.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ModelRegistry.saveRemoteConfig(CloudPreset.preset(id: "anthropic")!.config(model: "a"), to: url)
        try ModelRegistry.saveRemoteConfig(CloudPreset.preset(id: "openai")!.config(model: "b"), to: url)
        try ModelRegistry.saveRemoteConfig(CloudPreset.preset(id: "anthropic")!.config(model: "c"), to: url)
        let loaded = try ModelRegistry.loadRemoteConfigs(from: url)
        XCTAssertEqual(loaded.map(\.id).sorted(), ["anthropic", "openai"])
        XCTAssertEqual(loaded.first { $0.id == "anthropic" }?.modelIdentifier, "c")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("Bearer"))
    }
}

final class ProviderUsageParsingTests: XCTestCase {
    func testOpenAIFinalChunk() {
        XCTAssertEqual(RemoteAPIProvider.openAIUsage(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7}}"#),
                       GenerationUsage(promptTokens: 12, completionTokens: 7))
        XCTAssertNil(RemoteAPIProvider.openAIUsage(#"{"choices":[{"delta":{"content":"x"}}]}"#))
    }
    func testAnthropicStartAndDelta() {
        let a = RemoteAPIProvider.anthropicUsage(#"{"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}"#)
        XCTAssertEqual(a?.prompt, 25)
        let b = RemoteAPIProvider.anthropicUsage(#"{"type":"message_delta","usage":{"output_tokens":42}}"#)
        XCTAssertEqual(b?.completion, 42); XCTAssertNil(b?.prompt)
        XCTAssertNil(RemoteAPIProvider.anthropicUsage(#"{"type":"content_block_delta"}"#))
    }
}
