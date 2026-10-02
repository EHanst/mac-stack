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
    /// Weights resident in GPU memory once loaded, for the context budget.
    public var residentWeightBytes: Int = Int(7.14 * Double(1 << 30))
    /// Measured memory model for this model (see `ContextBudget`).
    public var contextBudget: ContextBudget = .bonsai27B2bit
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

    /// Qwen3.5-4B, OptiQ mixed 4/8-bit, plus its multi-token-prediction head (`optiq/mtp.safetensors`),
    /// which the runtime uses to speculate on rewrites. The vision tower is not fetched.
    public static let qwen35_4b = ModelCatalogEntry(
        id: "qwen3.5-4b-optiq",
        displayName: "Qwen3.5 4B",
        kind: .chat,
        repository: "mlx-community/Qwen3.5-4B-OptiQ-4bit",
        installSubpath: "Models/Qwen3.5-4B-OptiQ-4bit",
        include: [
            "config.json", "generation_config.json", "model.safetensors",
            "tokenizer.json", "tokenizer_config.json", "optiq/mtp.safetensors",
        ],
        requiredFiles: ["config.json", "model.safetensors", "tokenizer.json"],
        approximateBytes: 3_360_000_000,
        minimumRAMBytes: 8 << 30,
        licenseName: "Apache License 2.0",
        licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
        attribution: "Qwen3.5 by Qwen (Alibaba Cloud), Apache 2.0. Quantized by mlx-optiq.",
        residentWeightBytes: Int(3.3 * Double(1 << 30)),
        contextBudget: .qwen35_4b)

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

    public static let all: [ModelCatalogEntry] = [bonsai27B, qwen35_4b, bgeSmall]

    /// Chat models, most capable first.
    public static let chatModels: [ModelCatalogEntry] = [bonsai27B, qwen35_4b]

    /// Macs with at least this much memory get the 27B by default; below it, the 4B.
    public static let largeModelRAMBytes: UInt64 = 24 << 30

    /// The chat model to offer on a Mac with `ramBytes`. A model already installed (and able to run
    /// here) wins over the tier default, so nobody is asked to download a second one.
    public static func recommendedChat(forRAM ramBytes: UInt64, installed: Set<String> = []) -> ModelCatalogEntry {
        let runnable = chatModels.filter { ($0.minimumRAMBytes ?? 0) <= ramBytes }
        let have = runnable.filter { installed.contains($0.id) }
        let pool = have.isEmpty ? runnable : have
        let tierDefault = qwen35_4b
        return pool.first { $0.id == tierDefault.id } ?? pool.first ?? qwen35_4b
    }
}
