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
