import Foundation
import MLX
import MLXNN
import MLXRandom
import Tokenizers
import os

// MARK: - Index

private struct SafetensorsIndex: Codable {
    let weightMap: [String: String]
    enum CodingKeys: String, CodingKey { case weightMap = "weight_map" }
}

// MARK: - LocalMLXProvider

public actor LocalMLXProvider: ModelProvider {

    public nonisolated let id: ProviderID
    public nonisolated let capabilities: ProviderCapabilities = [.textGeneration, .streaming]

    private let modelDirectory: URL
    private let logger = Logger(subsystem: "com.vibecockpit", category: "LocalMLXProvider")

    private var model: Qwen35ForCausalLM?
    private var tokenizer: (any Tokenizer)?
    private var _runtime: ModelRuntime?

    private var runtime: ModelRuntime {
        if let r = _runtime { return r }
        let r = ModelRuntime(
            loader: { [weak self] in try await self?._loadModel() },
            unloader: { [weak self] in await self?._unloadModel() },
            idleTimeout: .seconds(300)
        )
        _runtime = r
        return r
    }

    public init(id: ProviderID, modelDirectory: URL) {
        self.id = id
        self.modelDirectory = modelDirectory
    }

    private func _loadModel() async throws {
        _ = try await ensureLoaded()
    }

    private func _unloadModel() async {
        model = nil
        tokenizer = nil
        logger.info("Model weights unloaded (idle eviction)")
    }

    // MARK: ModelProvider

    public func generate(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await self.runGenerate(
                        messages: messages, options: options, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw LocalModelError.unsupportedOperation("embedding")
    }

    public func healthCheck() async -> ProviderHealth {
        guard ProcessInfo.processInfo.machineHardwareName.hasPrefix("arm") else {
            return .unavailable("Apple Silicon required for local MLX inference")
        }
        let safetensors = modelDirectory.appendingPathComponent("model.safetensors")
        let index       = modelDirectory.appendingPathComponent("model.safetensors.index.json")
        guard FileManager.default.fileExists(atPath: safetensors.path) ||
              FileManager.default.fileExists(atPath: index.path) else {
            return .unavailable("Model weights not found at \(modelDirectory.lastPathComponent)")
        }
        return model != nil ? .healthy : .degraded("Model not yet loaded — will load on first use")
    }

    // MARK: - Private

    private func runGenerate(
        messages: [Message],
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        try await runtime.acquire()
        defer { Task { await self.runtime.release() } }
        let (mdl, tok) = try await ensureLoaded()

        let prompt = buildPrompt(from: messages, tokenizer: tok)
        let inputIds = tok.encode(text: prompt, addSpecialTokens: true)
        let eosIds: Set<Int> = [tok.eosTokenId ?? 151645, 151643]

        var inputTokens = MLXArray(inputIds.map { Int32($0) })[.newAxis]
        var cache: [(key: MLXArray, value: MLXArray)?] = Array(
            repeating: nil, count: mdl.config.numHiddenLayers)

        var generated = 0
        let maxTokens = options.maxTokens > 0 ? options.maxTokens : 2048
        let temperature = Float(max(options.temperature, 0))

        repeat {
            let logits = mdl(inputTokens, cache: &cache)  // (1, 1, vocab)
            MLX.eval(logits)

            let nextId = sampleToken(logits[0, 0, 0...], temperature: temperature)
            if eosIds.contains(nextId) { break }

            let decoded = tok.decode(tokens: [nextId])
            continuation.yield(.token(decoded))
            generated += 1

            inputTokens = MLXArray([Int32(nextId)])[.newAxis]

            if !options.stopSequences.isEmpty {
                // Check stop sequences in the most recent decoded text
                let recent = decoded
                if options.stopSequences.contains(where: { recent.contains($0) }) { break }
            }
        } while generated < maxTokens

        continuation.yield(.finished(.stop))
        continuation.finish()
    }

    private func ensureLoaded() async throws -> (Qwen35ForCausalLM, any Tokenizer) {
        if let m = model, let t = tokenizer { return (m, t) }

        logger.info("Loading model from \(self.modelDirectory.lastPathComponent, privacy: .public)")

        let weights  = try loadWeights(from: modelDirectory)
        let config   = try loadConfig(from: modelDirectory)
        let hadamard = (try? loadHadamard(from: modelDirectory, weights: weights)) ?? .none

        let mdl = Qwen35ForCausalLM(weights: weights, config: config, hadamard: hadamard)
        let allW = mdl.allArrays()
        MLX.eval(allW)
        logger.info("Weights eval'd (\(allW.count, privacy: .public) tensors)")

        let tok = try await AutoTokenizer.from(modelFolder: modelDirectory)

        self.model     = mdl
        self.tokenizer = tok
        return (mdl, tok)
    }

    // MARK: - Weight loading

    private func loadWeights(from dir: URL) throws -> [String: MLXArray] {
        let single = dir.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: single.path) {
            return try MLX.loadArrays(url: single)
        }
        let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw LocalModelError.noWeightsFound(dir.path)
        }
        let idx = try JSONDecoder().decode(SafetensorsIndex.self,
                                           from: Data(contentsOf: indexURL))
        var all: [String: MLXArray] = [:]
        for shard in Set(idx.weightMap.values) {
            let shardWeights = try MLX.loadArrays(url: dir.appendingPathComponent(shard))
            all.merge(shardWeights) { a, _ in a }
        }
        return all
    }

    private func loadConfig(from dir: URL) throws -> Qwen35Config {
        let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Qwen35Config.from(dict: dict)
    }

    private func loadHadamard(from dir: URL, weights: [String: MLXArray]) throws -> HadamardMeta {
        let url = dir.appendingPathComponent("hadamard.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["block"] as? Int, block > 0 else { return .none }

        var rotations: [String: MLXArray?] = [:]
        var embeddingKeys = Set<String>()

        let linearKeys   = json["linear_keys"]    as? [String] ?? json["weights"] as? [String] ?? []
        let embKeys      = json["embedding_keys"] as? [String] ?? json["embeddings"] as? [String] ?? []
        let signsDict    = json["signs"]          as? [String: [Double]] ?? [:]

        for key in linearKeys + embKeys {
            let signs: MLXArray?
            if let sv = signsDict[key] {
                signs = MLXArray(sv.map { Float($0) })
            } else {
                signs = nil
            }
            rotations[key] = signs
        }
        for key in embKeys { embeddingKeys.insert(key) }

        return HadamardMeta(block: block, rotations: rotations, embeddingKeys: embeddingKeys)
    }

    // MARK: - Sampling

    private func sampleToken(_ logits: MLXArray, temperature: Float) -> Int {
        if temperature <= 0 {
            return argMax(logits).item(Int.self)
        }
        return MLXRandom.categorical(logits / temperature).item(Int.self)
    }

    // MARK: - Chat template

    private func buildPrompt(from messages: [Message], tokenizer: any Tokenizer) -> String {
        var result = ""
        for msg in messages {
            switch msg.role {
            case .system:
                result += "<|im_start|>system\n\(msg.content)<|im_end|>\n"
            case .user:
                result += "<|im_start|>user\n\(msg.content)<|im_end|>\n"
            case .assistant:
                result += "<|im_start|>assistant\n\(msg.content)<|im_end|>\n"
            case .tool:
                result += "<|im_start|>tool\n\(msg.content)<|im_end|>\n"
            }
        }
        result += "<|im_start|>assistant\n"
        return result
    }
}

// MARK: - Errors

public enum LocalModelError: LocalizedError {
    case noWeightsFound(String)
    case missingWeight(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .noWeightsFound(let dir):    return "No .safetensors files found in \(dir)"
        case .missingWeight(let key):     return "Required weight key missing: \(key)"
        case .unsupportedOperation(let op): return "Operation not supported: \(op)"
        }
    }
}

// MARK: - ProcessInfo extension for arch detection

private extension ProcessInfo {
    var machineHardwareName: String {
        var sysInfo = utsname()
        uname(&sysInfo)
        return withUnsafeBytes(of: &sysInfo.machine) { rawPtr -> String in
            let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
    }
}
