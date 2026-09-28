import Foundation
import os

/// In-process LLM inference via mlx-swift on Apple Silicon Unified Memory.
///
/// STUB: mlx-swift ≤ 0.31.6 pulls swift-argument-parser which breaks on macOS 26 SDK 27.
/// Re-enable by:
///   1. Uncommenting mlx-swift + swift-transformers in Package.swift
///   2. Replacing this file with the full implementation in Sources/VibeCockpitMLX/LocalMLXProvider.swift
///
/// The full implementation supports:
///   - SafeTensors weight loading via MLX.loadArrays
///   - HuggingFace tokenizer via AutoTokenizer.from(modelFolder:)
///   - Generic causal transformer forward pass (Llama/Mistral/Qwen layout)
///   - Speculative decoding with an optional draft provider
public actor LocalMLXProvider: ModelProvider {

    public nonisolated let id: ProviderID
    public nonisolated let capabilities: ProviderCapabilities = [
        .textGeneration, .embedding, .streaming, .speculativeDraft
    ]

    private let modelDirectory: URL
    private let logger = Logger(subsystem: "com.vibecockpit", category: "LocalMLXProvider")

    public var draftProvider: (any ModelProvider)?

    public init(id: ProviderID, modelDirectory: URL) {
        self.id = id
        self.modelDirectory = modelDirectory
    }

    public func generate(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LocalModelError.mlxUnavailable)
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw LocalModelError.mlxUnavailable
    }

    public func healthCheck() async -> ProviderHealth {
        .unavailable("mlx-swift not linked — see LocalMLXProvider.swift stub comment")
    }
}

public enum LocalModelError: LocalizedError {
    case mlxUnavailable
    case noWeightsFound(String)
    case missingWeight(String)

    public var errorDescription: String? {
        switch self {
        case .mlxUnavailable:
            return "Local MLX inference is not available: mlx-swift is not linked (macOS 26 SDK 27 compatibility)"
        case .noWeightsFound(let dir):
            return "No .safetensors files found in \(dir)"
        case .missingWeight(let key):
            return "Required weight key missing: \(key)"
        }
    }
}
