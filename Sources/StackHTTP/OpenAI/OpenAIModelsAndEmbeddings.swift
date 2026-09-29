import Foundation
import StackCore

// MARK: - /v1/models

public enum OpenAIModelList {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let ownedBy: String
        public init(id: String, ownedBy: String) { self.id = id; self.ownedBy = ownedBy }
    }

    public static func json(_ entries: [Entry], created: Date = Date()) -> String {
        struct Model: Encodable { let id: String; let object = "model"; let created: Int; let owned_by: String }
        struct Body: Encodable { let object = "list"; let data: [Model] }
        let t = Int(created.timeIntervalSince1970)
        return OpenAIJSON.encode(Body(data: entries.map { Model(id: $0.id, created: t, owned_by: $0.ownedBy) }))
    }
}

// MARK: - /v1/embeddings

public struct OpenAIEmbeddingsRequest: Decodable, Sendable {
    public enum Input: Decodable, Sendable, Equatable {
        case one(String), many([String])
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) }
            else if let m = try? c.decode([String].self) { self = .many(m) }
            else { throw OpenAIError.invalidRequest("'input' must be a string or an array of strings (token arrays aren't supported).", param: "input") }
        }
    }
    public let model: String?
    public let input: Input?
    public let encodingFormat: String?
    enum CodingKeys: String, CodingKey { case model, input, encodingFormat = "encoding_format" }

    /// Largest batch accepted in one call.
    public static let maxInputs = 256

    public func texts() throws -> [String] {
        guard let input else { throw OpenAIError.invalidRequest("'input' is required.", param: "input") }
        if let f = encodingFormat, f != "float" {
            throw OpenAIError.invalidRequest("Only encoding_format \"float\" is supported.", param: "encoding_format")
        }
        let list: [String]
        switch input { case .one(let s): list = [s]; case .many(let m): list = m }
        guard !list.isEmpty else { throw OpenAIError.invalidRequest("'input' must not be empty.", param: "input") }
        guard list.count <= Self.maxInputs else {
            throw OpenAIError.invalidRequest("At most \(Self.maxInputs) inputs per request.", param: "input")
        }
        return list
    }
}

public enum OpenAIEmbeddingsResponse {
    public static func json(vectors: [[Float]], model: String, promptTokens: Int) -> String {
        struct Item: Encodable { let object = "embedding"; let index: Int; let embedding: [Float] }
        struct Usage: Encodable { let prompt_tokens: Int; let total_tokens: Int }
        struct Body: Encodable { let object = "list"; let data: [Item]; let model: String; let usage: Usage }
        return OpenAIJSON.encode(Body(
            data: vectors.enumerated().map { Item(index: $0.offset, embedding: $0.element) },
            model: model, usage: Usage(prompt_tokens: promptTokens, total_tokens: promptTokens)))
    }
}
