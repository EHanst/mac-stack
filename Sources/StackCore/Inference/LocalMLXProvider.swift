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

    /// Cache snapshots at message boundaries of recent prompts, for prefix reuse across turns.
    private var snapshots = PromptSnapshotStore<Qwen35Cache>()
    /// Timing and memory for the most recent request (read by the benchmark harness and diagnostics).
    public private(set) var lastStats: GenerationStats?
    /// Bytes to wire in GPU memory while generating (weights + headroom).
    private var wiredBytes = 0

    /// Memory/throughput knobs. Smaller prefill chunks lower peak memory at some cost in speed.
    public struct Tuning: Sendable, Equatable {
        /// Tokens per prefill chunk. Bounds the O(L²) linear-attention intermediates and the
        /// lazy graph size so long prompts don't spike memory. 128 measured ≈2 GiB lower peak
        /// than 512 with no prefill slowdown (docs/plans/m0-status.md).
        public var prefillChunkSize = 128
        /// MLX buffer-cache ceiling; the default is unbounded and grows with prompt length.
        public var bufferCacheLimit = 1 << 30
        public init() {}
    }
    public private(set) var tuning = Tuning()
    /// Bytes of model weights once loaded (0 before load).
    public private(set) var weightBytes = 0
    /// Memory model used to keep prompts inside what this Mac can safely hold.
    public var budget = ContextBudget.bonsai27B2bit

    /// How much prompt fits right now, given this Mac's GPU working set, what we already hold,
    /// and what other apps have left free. A Metal out-of-memory error aborts the whole
    /// process, so this is checked *before* dispatch rather than caught after.
    public func contextVerdict() -> ContextBudget.Verdict {
        budget.verdict(
            workingSetBytes: GPU.maxRecommendedWorkingSetBytes() ?? Int(ProcessInfo.processInfo.physicalMemory) * 3 / 4,
            weightBytes: weightBytes > 0 ? weightBytes : onDiskWeightBytes(),
            currentActiveBytes: model != nil ? Memory.activeMemory : 0,
            availableSystemBytes: SystemMemory.availableBytes())
    }

    public func maxContextTokens() async -> Int? {
        switch contextVerdict() {
        case .ok(let n), .belowFloor(let n): return n
        }
    }

    private func onDiskWeightBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "safetensors" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Drop all cached prompt prefixes (frees their memory; the next request prefills in full).
    public func clearPromptCache() { snapshots.removeAll() }

    /// Account for another resident model (the embedder) in the memory budget.
    public func reserveMemory(bytes: Int) { budget.reservedBytes = bytes }

    /// Replace the memory model (benchmarks bypass it to measure beyond the current limit).
    public func setBudget(_ b: ContextBudget) { budget = b }

    public func setTuning(_ t: Tuning) {
        tuning = t
        if model != nil { Memory.cacheLimit = t.bufferCacheLimit }
    }

    private var runtime: ModelRuntime {
        if let r = _runtime { return r }
        let r = ModelRuntime(
            loader: { [weak self] in try await self?._loadModel() },
            unloader: { [weak self] in await self?._unloadModel() },
            idleTimeout: .seconds(1800)
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
        snapshots.removeAll()
        Memory.clearCache()
        logger.info("Model weights unloaded (idle eviction)")
    }

    // MARK: ModelProvider

    public func generate(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await self.runGenerate(
                        messages: messages, options: options, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Stop burning GPU time as soon as the consumer goes away.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw LocalModelError.unsupportedOperation("embedding")
    }

    /// Diagnostics: the model's most likely next tokens after plain `text` (no chat template).
    /// Used to check the model computes sensibly — e.g. "The capital of France is" → " Paris".
    public func debugTopTokens(after text: String, count: Int = 5) async throws -> [(token: String, probability: Float)] {
        let (mdl, tok) = try await ensureLoaded()
        let ids = tok.encode(text: text, addSpecialTokens: false).map { Int32($0) }
        guard let last = ids.last else { return [] }
        let cache = mdl.makeCache()
        if ids.count > 1 {
            mdl.prefill(MLXArray(Array(ids.dropLast()))[.newAxis], cache: cache)
            MLX.eval(cache.stateArrays)
        }
        let logits = mdl(MLXArray([last])[.newAxis], cache: cache)          // [1, vocab]
        let probs = softmax(logits.asType(.float32), axis: -1)[0]
        let order = argSort(-probs)[0..<count]
        MLX.eval(probs, order)
        return order.asArray(Int32.self).map { id in
            (tok.decode(tokens: [Int(id)]), probs[Int(id)].item(Float.self))
        }
    }

    public func warmUp() async throws {
        try await ensureLoaded()
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
        if case .belowFloor = contextVerdict() {
            return .unavailable("Not enough free GPU memory for local inference right now")
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

        let (promptIds, boundaries) = tokenize(messages, with: tok)
        let verdict = contextVerdict()
        let limit: Int
        switch verdict { case .ok(let n), .belowFloor(let n): limit = n }
        if promptIds.count > limit {
            throw LocalModelError.contextTooLarge(promptTokens: promptIds.count, limit: limit)
        }
        guard !promptIds.isEmpty else {
            continuation.yield(.finished(.stop))
            continuation.finish()
            return
        }

        // Keep weights wired for the duration of the request so the OS can't page them out
        // mid-generation (same policy as mlx-lm's wired_limit context).
        let ticket = WiredMemoryTicket(size: wiredBytes, policy: WiredSumPolicy(), kind: .active)
        _ = await ticket.start()
        do {
            try generateLoop(model: mdl, tokenizer: tok, promptIds: promptIds, boundaries: boundaries,
                             startsWithSystem: messages.first?.role == .system,
                             options: options, continuation: continuation)
        } catch {
            _ = await ticket.end()
            throw error
        }
        _ = await ticket.end()
    }

    /// Synchronous prefill + decode. Runs to completion on the provider actor.
    private func generateLoop(
        model mdl: Qwen35ForCausalLM,
        tokenizer tok: any Tokenizer,
        promptIds: [Int32],
        boundaries: [Int],
        startsWithSystem: Bool,
        options: GenerationOptions,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) throws {
        // 248044 = <|endoftext|>, 248046 = <|im_end|> (Bonsai/Qwen3 tokenizer)
        let eosIds: Set<Int> = [tok.eosTokenId ?? 248044, 248046]
        let maxTokens = options.maxTokens > 0 ? options.maxTokens : GenerationOptions.defaultMaxTokens
        let sampling = options.sampling ?? .bonsaiInstruct

        // ── Prefill ────────────────────────────────────────────────────────────────
        // The last prompt token is held back and fed through the normal decode step, so the
        // first sampled token comes out of the same pipelined path as every other token.
        let prefillStart = Date()
        let lastIndex = promptIds.count - 1

        let cache: Qwen35Cache
        var consumed = 0
        // Restore the longest stored prefix of this prompt (recurrent state can't be rewound, so
        // only an exact token-prefix match is reusable — but any stored boundary will do).
        if let hit = snapshots.bestMatch(for: promptIds, maxLength: lastIndex) {
            cache = hit.payload.fork()
            consumed = hit.tokens.count
        } else {
            cache = mdl.makeCache()
        }

        // Prefill in chunks cut at message boundaries so a snapshot can be taken at each one.
        var stops = PrefillPlan.snapshotStops(
            boundaries: boundaries, restoredUpTo: consumed, prefillEnd: lastIndex)
        if lastIndex > consumed, !stops.contains(lastIndex) { stops.append(lastIndex) }   // tail
        for range in PrefillPlan.chunks(
            from: consumed, to: lastIndex, chunk: tuning.prefillChunkSize, stops: stops) {
            try Task.checkCancellation()
            let chunk = MLXArray(Array(promptIds[range]))[.newAxis]
            mdl.prefill(chunk, cache: cache)
            MLX.eval(cache.stateArrays)
            if stops.contains(range.upperBound) {
                let isBoundary = boundaries.contains(range.upperBound)
                let isSystemEnd = startsWithSystem && range.upperBound == boundaries.first
                let kind: PromptSnapshotStore<Qwen35Cache>.Kind =
                    isSystemEnd ? .system : (isBoundary ? .boundary : .tail)
                let snap = cache.fork()
                snapshots.insert(
                    tokens: Array(promptIds[0..<range.upperBound]), payload: snap,
                    bytes: snap.stateArrays.reduce(0) { $0 + $1.nbytes }, kind: kind)
            }
        }
        snapshots.prune(keepingPrefixesOf: promptIds)
        let prefilled = lastIndex - consumed
        let prefillSecs = Date().timeIntervalSince(prefillStart)

        // ── Decode (pipelined) ─────────────────────────────────────────────────────
        // Sampling stays on the GPU: step n+1 is enqueued from the *lazy* token of step n
        // before we block to read token n, so graph construction and dispatch overlap GPU
        // execution instead of serialising with it.
        // Presence penalty needs to know which tokens this reply already contains; that mask is
        // updated lazily on the GPU like everything else in the loop.
        let usesPenalty = sampling.presencePenalty != 0
        var seen: MLXArray? = usesPenalty ? MLXArray.zeros([1, mdl.config.vocabSize]) : nil
        func step(_ token: MLXArray) -> MLXArray {
            let logits = mdl(token, cache: cache)
            let next = TokenSampler.sample(logits, sampling, seen: seen)
            if let current = seen {
                seen = maximum(current, TokenSampler.oneHot(next, vocab: logits.dim(-1)))
            }
            return next
        }

        let decodeStart = Date()
        var y = step(MLXArray([promptIds[lastIndex]])[.newAxis])
        MLX.asyncEval(y)

        var detok = StreamingDetokenizer { tok.decode(tokens: $0) }
        var filter = StopSequenceFilter(stops: options.stopSequences)
        var generated = 0
        var finish = FinishReason.length
        var stopped = false

        /// Route text through the stop filter; returns true when a stop sequence was hit.
        func emit(_ text: String) -> Bool {
            let r = filter.push(text)
            if !r.emit.isEmpty { continuation.yield(.token(r.emit)) }
            return r.stopped
        }

        while generated < maxTokens {
            if Task.isCancelled { finish = .stop; stopped = true; break }

            var following: MLXArray?
            if generated + 1 < maxTokens {
                let next = step(y.reshaped([1, 1]))
                MLX.asyncEval(next)
                following = next
            }

            let id = y.item(Int.self)  // blocks until this token is ready
            generated += 1
            if eosIds.contains(id) { finish = .stop; stopped = true; break }

            let text = detok.append(id)
            if !text.isEmpty, emit(text) { finish = .stop; stopped = true; break }

            guard let next = following else { break }
            y = next
        }

        if !stopped {
            let tail = detok.flush()
            if !tail.isEmpty, emit(tail) { finish = .stop; stopped = true }
        }
        if !stopped {
            let rest = filter.flush()
            if !rest.isEmpty { continuation.yield(.token(rest)) }
        }

        let decodeSecs = Date().timeIntervalSince(decodeStart)
        let decodeRate = Double(generated) / max(decodeSecs, 1e-6)
        let prefillRate = Double(prefilled) / max(prefillSecs, 1e-6)
        logger.info("prefill \(prefilled, privacy: .public) tok (+\(consumed, privacy: .public) cached) @ \(prefillRate, format: .fixed(precision: 1), privacy: .public) tok/s; decode \(generated, privacy: .public) tok @ \(decodeRate, format: .fixed(precision: 1), privacy: .public) tok/s")

        lastStats = GenerationStats(
            promptTokens: promptIds.count, cachedTokens: consumed,
            prefillSeconds: prefillSecs, generatedTokens: generated,
            decodeSeconds: decodeSecs, peakGPUBytes: Memory.peakMemory)

        continuation.yield(.finished(finish))
        continuation.finish()
    }

    private func ensureLoaded() async throws -> (Qwen35ForCausalLM, any Tokenizer) {
        if let m = model, let t = tokenizer { return (m, t) }

        logger.info("Loading model from \(self.modelDirectory.lastPathComponent, privacy: .public)")

        var weights  = try loadWeights(from: modelDirectory)
        let config   = try loadConfig(from: modelDirectory)
        let hadamard = (try? loadHadamard(from: modelDirectory, weights: weights)) ?? .none

        // The store is the only owner from here on: fused projections consume their source
        // tensors, so the unfused copies are freed layer by layer during construction.
        let store = WeightStore(weights)
        weights = [:]
        let mdl = Qwen35ForCausalLM(weights: store, config: config, hadamard: hadamard)
        let allW = mdl.allArrays()
        MLX.eval(allW)
        logger.info("Weights eval'd (\(allW.count, privacy: .public) tensors)")

        Memory.cacheLimit = tuning.bufferCacheLimit
        weightBytes = allW.reduce(0) { $0 + $1.nbytes }
        wiredBytes = min(weightBytes + (2 << 30), GPU.maxRecommendedWorkingSetBytes() ?? Int.max)

        let tok = try await AutoTokenizer.from(modelFolder: modelDirectory)
        warmKernels(mdl)

        self.model     = mdl
        self.tokenizer = tok
        return (mdl, tok)
    }

    // MARK: - Weight loading

    private func loadWeights(from dir: URL) throws -> [String: MLXArray] {
        var all: [String: MLXArray] = [:]
        let single = dir.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: single.path) {
            all = try MLX.loadArrays(url: single)
        } else {
            let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
            guard FileManager.default.fileExists(atPath: indexURL.path) else {
                throw LocalModelError.noWeightsFound(dir.path)
            }
            let idx = try JSONDecoder().decode(SafetensorsIndex.self,
                                               from: Data(contentsOf: indexURL))
            for shard in Set(idx.weightMap.values) {
                let shardWeights = try MLX.loadArrays(url: dir.appendingPathComponent(shard))
                all.merge(shardWeights) { a, _ in a }
            }
        }
        let lmPrefix = "language_model."
        return Dictionary(uniqueKeysWithValues: all.map { k, v in
            (k.hasPrefix(lmPrefix) ? String(k.dropFirst(lmPrefix.count)) : k, v)
        })
    }

    private func loadConfig(from dir: URL) throws -> Qwen35Config {
        let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let flat = (dict["text_config"] as? [String: Any]) ?? dict
        return Qwen35Config.from(dict: flat)
    }

    private func loadHadamard(from dir: URL, weights: [String: MLXArray]) throws -> HadamardMeta {
        let url = dir.appendingPathComponent("hadamard.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["prism.hadamard.block_size"] as? Int, block > 0 else { return .none }

        let signWidths = json["prism.hadamard.sign_widths"] as? [Int] ?? []
        let signValues = json["prism.hadamard.sign_values"] as? [Double] ?? []

        var widthSignMap: [Int: MLXArray] = [:]
        var offset = 0
        for w in signWidths {
            guard offset + w <= signValues.count else { break }
            widthSignMap[w] = MLXArray(Array(signValues[offset..<(offset + w)]).map { Float($0) })
            offset += w
        }

        let lmPrefix = "language_model."
        func toPrefix(_ raw: String) -> String {
            let k = raw.hasPrefix(lmPrefix) ? String(raw.dropFirst(lmPrefix.count)) : raw
            return k.hasSuffix(".weight") ? String(k.dropLast(".weight".count)) : k
        }
        func signsFor(_ prefix: String) -> MLXArray? {
            guard let scales = weights["\(prefix).scales"],
                  let lastDim = scales.shape.last else { return nil }
            return widthSignMap[lastDim * 128]
        }

        var rotations: [String: MLXArray?] = [:]
        var embeddingKeys = Set<String>()

        for rawKey in json["prism.hadamard.weight_names"] as? [String] ?? [] {
            let prefix = toPrefix(rawKey)
            rotations[prefix] = signsFor(prefix)
        }
        for rawKey in json["prism.hadamard.inverse_weight_names"] as? [String] ?? [] {
            let prefix = toPrefix(rawKey)
            embeddingKeys.insert(prefix)
            if rotations[prefix] == nil { rotations[prefix] = signsFor(prefix) }
        }

        return HadamardMeta(block: block, rotations: rotations, embeddingKeys: embeddingKeys)
    }

    // MARK: - Kernel warm-up

    /// Run one throw-away prefill chunk and decode step so Metal pipeline compilation and
    /// first-dispatch costs land at load time rather than in the user's first request.
    private func warmKernels(_ mdl: Qwen35ForCausalLM) {
        let cache = mdl.makeCache()
        let prompt = MLXArray(Array(repeating: Int32(1), count: 16))[.newAxis]
        mdl.prefill(prompt, cache: cache)
        MLX.eval(cache.stateArrays)
        let logits = mdl(MLXArray([Int32(1)])[.newAxis], cache: cache)
        MLX.eval(logits)
        Memory.clearCache()
        logger.info("Kernels warmed")
    }

    // MARK: - Sampling

    /// Lazily sample a token id `[1]` from `[1, vocab]` logits without leaving the GPU.
    // MARK: - Chat template

    /// Token ids for the prompt plus the token offset at the end of each message.
    ///
    /// Segments are tokenised separately to find message boundaries; ChatML markers are special
    /// tokens, so this matches tokenising the whole text. That is verified each time, and if the
    /// two ever disagree the boundaries are dropped (only the tail snapshot is kept) rather than
    /// trusted.
    private func tokenize(_ messages: [Message], with tok: any Tokenizer) -> (ids: [Int32], boundaries: [Int]) {
        let rendered = ChatPromptRenderer.render(messages)
        let whole = tok.encode(text: rendered.text, addSpecialTokens: true)

        var joined: [Int] = []
        var boundaries: [Int] = []
        for segment in rendered.segments {
            joined += tok.encode(text: segment, addSpecialTokens: false)
            boundaries.append(joined.count)
        }
        joined += tok.encode(text: rendered.generation, addSpecialTokens: false)

        guard joined == whole else {
            logger.notice("segment tokenisation differs from whole-prompt tokenisation; message-boundary snapshots disabled for this request")
            return (whole.map { Int32($0) }, [])
        }
        return (whole.map { Int32($0) }, boundaries)
    }
}

// MARK: - Errors

public enum LocalModelError: LocalizedError {
    case noWeightsFound(String)
    case missingWeight(String)
    case unsupportedOperation(String)
    case contextTooLarge(promptTokens: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .noWeightsFound(let dir):    return "No .safetensors files found in \(dir)"
        case .missingWeight(let key):     return "Required weight key missing: \(key)"
        case .unsupportedOperation(let op): return "Operation not supported: \(op)"
        case .contextTooLarge(let n, let limit):
            return "This conversation (\(n) tokens) is larger than this Mac can safely process locally right now (about \(limit) tokens). Start a new chat, or switch to a cloud provider."
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
