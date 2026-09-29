import Foundation
import MLXLMCommon
import Tokenizers

/// Lets `MLXEmbedders` use swift-transformers tokenizers (the same ones the Bonsai path uses).
public struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let inner = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizer(inner)
    }
}

public struct TransformersTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let inner: any Tokenizers.Tokenizer
    public init(_ inner: any Tokenizers.Tokenizer) { self.inner = inner }

    public func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    public func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    public func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
    public func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }
    public var bosToken: String? { inner.bosToken }
    public var eosToken: String? { inner.eosToken }
    public var unknownToken: String? { inner.unknownToken }

    public func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate   // embedders never use chat templates
    }
}
