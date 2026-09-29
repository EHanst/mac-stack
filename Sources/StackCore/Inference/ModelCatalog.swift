import Foundation

/// A model the app knows how to install: where it comes from, which of the repository's files
/// it needs (never the Python/runtime extras), and what to tell the user about it.
public struct ModelCatalogEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case chat, embedder }

    public let id: String
    public let displayName: String
    public let kind: Kind
    /// Hugging Face repository, `owner/name`. Files are fetched directly from there; we never re-host.
    public let repository: String
    /// Install location relative to the app's Application Support folder. Matches the layout
    /// `ModelRegistry` and `LocalEmbedder` already scan, so an existing install is recognised.
    public let installSubpath: String
    /// Exact repository paths to download.
    public let include: [String]
    /// Files that must exist for the model to count as installed.
    public let requiredFiles: [String]
    public let approximateBytes: Int64
    /// Smallest Mac (unified memory) this model is offered on; nil = any.
    public let minimumRAMBytes: UInt64?
    public let licenseName: String
    public let licenseURL: URL
    /// Credit the model's authors ask for; shown alongside the licence.
    public let attribution: String?
}

public enum ModelCatalog {

    public static let bonsai27B = ModelCatalogEntry(
        id: "bonsai-27b",
        displayName: "Ternary Bonsai 27B",
        kind: .chat,
        repository: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit",
        installSubpath: "Models/Bonsai-27B",
        include: [
            "config.json", "generation_config.json", "hadamard.json", "model.safetensors",
            "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "LICENSE", "NOTICE.txt",
        ],
        requiredFiles: ["config.json", "model.safetensors", "tokenizer.json"],
        approximateBytes: 8_610_000_000,
        minimumRAMBytes: 16 << 30,
        licenseName: "Apache License 2.0",
        licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
        attribution: "Created using Bonsai by Prism ML. Built from Qwen (Alibaba Cloud), Apache 2.0.")

    public static let bgeSmall = ModelCatalogEntry(
        id: "bge-small-en-v1.5",
        displayName: "bge-small (code search)",
        kind: .embedder,
        repository: "BAAI/bge-small-en-v1.5",
        installSubpath: "Models/Embedders/BAAI--bge-small-en-v1.5",
        include: [
            "1_Pooling/config.json", "config.json", "config_sentence_transformers.json",
            "model.safetensors", "modules.json", "sentence_bert_config.json",
            "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.txt",
        ],
        requiredFiles: ["config.json", "model.safetensors", "tokenizer.json"],
        approximateBytes: 134_000_000,
        minimumRAMBytes: nil,
        licenseName: "MIT License",
        licenseURL: URL(string: "https://opensource.org/licenses/MIT")!,
        attribution: nil)

    public static let all: [ModelCatalogEntry] = [bonsai27B, bgeSmall]
}
