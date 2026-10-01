import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore

private func info(_ id: String, kind: ModelInfo.Kind = .local, caps: ProviderCapabilities) -> ModelInfo {
    ModelInfo(id: id, displayName: id, kind: kind, capabilities: caps, health: .healthy)
}

@Suite("Model listing")
struct ModelListingTests {
    @Test func builtInEmbedderIsHidden() {
        let chat = info("local:bonsai", caps: [.textGeneration, .streaming])
        let embedder = info(LocalEmbedder.defaultID, caps: [.embedding])
        #expect(ModelListing.visible([chat, embedder]).map(\.id) == ["local:bonsai"])
    }

    @Test func otherEmbeddingProvidersStayVisible() {
        let remoteEmbedder = info("openai-embeddings", kind: .remote, caps: [.embedding])
        #expect(ModelListing.visible([remoteEmbedder]).map(\.id) == ["openai-embeddings"])
    }
}
