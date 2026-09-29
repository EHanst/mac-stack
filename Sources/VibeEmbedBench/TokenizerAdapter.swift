import Foundation
import MLXLMCommon
import Tokenizers

/// Lets `MLXEmbedders` use swift-transformers tokenizers (the same ones the Bonsai path uses).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let inner = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizer(inner)
    }
}

struct TransformersTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let inner: any Tokenizers.Tokenizer
    init(_ inner: any Tokenizers.Tokenizer) { self.inner = inner }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }
    var bosToken: String? { inner.bosToken }
    var eosToken: String? { inner.eosToken }
    var unknownToken: String? { inner.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate   // embedders never use chat templates
    }
}
