import Darwin
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import StackCore

// kokoro-embed-bench — which embedding model should back offline code search?
//   swift run -c release KokoroEmbedBench [--source DIR] [--models qwen3,bge,nomic] [--json out.json]
// Corpus: every Swift declaration chunk under Sources/ (excluding this tool). Queries: EvalSet.swift.
// Compares BM25 (existing FTS5 path), dense-only, and hybrid (RRF, as IndexingPipeline does).

struct ModelSpec {
    let key: String
    let directory: String
    let queryPrefix: String
    let documentPrefix: String
    let appendToken: String?   // Qwen3-Embedding pools the last token, which must be <|endoftext|>
    let layerNorm: Bool        // nomic applies layer norm before normalising
    var dropLearnedPositions = false   // nomic-bert is rotary-only; mlx-swift-lm 3.31.3 builds a position table anyway
    let maxTokens = 512
}

let modelSpecs: [ModelSpec] = [
    ModelSpec(key: "qwen3", directory: "mlx-community--Qwen3-Embedding-0.6B-4bit-DWQ",
              queryPrefix: "Instruct: Given a natural language question about a Swift codebase, retrieve the declaration that answers it\nQuery: ",
              documentPrefix: "", appendToken: "<|endoftext|>", layerNorm: false),
    ModelSpec(key: "bge", directory: "BAAI--bge-small-en-v1.5",
              queryPrefix: "Represent this sentence for searching relevant passages: ",
              documentPrefix: "", appendToken: nil, layerNorm: false),
    ModelSpec(key: "nomic", directory: "nomic-ai--nomic-embed-text-v1.5",
              queryPrefix: "search_query: ", documentPrefix: "search_document: ",
              appendToken: nil, layerNorm: true, dropLearnedPositions: true),
]

// MARK: - Options

struct Options: Sendable {
    var sourceDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources")
    var wanted = Set(modelSpecs.map(\.key))
    var jsonOut: URL?
    var dumpCorpus: URL?
    var selfTest = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--source": if let v = it.next() { o.sourceDir = URL(fileURLWithPath: v) }
            case "--models": if let v = it.next() { o.wanted = Set(v.split(separator: ",").map(String.init)) }
            case "--json": if let v = it.next() { o.jsonOut = URL(fileURLWithPath: v) }
            case "--self-test": o.selfTest = true
            case "--dump-corpus": if let v = it.next() { o.dumpCorpus = URL(fileURLWithPath: v) }
            default: FileHandle.standardError.write(Data("ignored argument: \(a)\n".utf8))
            }
        }
        return o
    }
}

let embedderRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/VibeCockpit/Models/Embedders")

// MARK: - Corpus

/// Synchronous: `FileManager.DirectoryEnumerator` can't be iterated from async code.
func swiftFiles(in dir: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var out: [URL] = []
    while let item = e.nextObject() as? URL {
        // Exclude the benchmark tools: their eval set literally contains the queries.
        if item.pathExtension == "swift", !item.path.contains("/KokoroEmbedBench/"), !item.path.contains("/KokoroBench/") {
            out.append(item)
        }
    }
    return out.sorted { $0.path < $1.path }
}

func loadCorpus(sourceDir: URL) async throws -> [CodeChunk] {
    let chunker = ASTChunker()
    var chunks: [CodeChunk] = []
    for url in swiftFiles(in: sourceDir) { chunks += try await chunker.chunks(for: url) }
    return chunks
}

func isRelevant(_ q: EvalQuery, path: String, content: String) -> Bool {
    path.hasSuffix("/" + q.file) && content.contains(q.marker)
}

// MARK: - Metrics

struct Metrics: Codable {
    var recall1 = 0.0, recall5 = 0.0, recall10 = 0.0, mrr10 = 0.0
}

/// `rankedRelevance[i]` = for query i, the booleans of its top results in order.
func metrics(_ rankedRelevance: [[Bool]]) -> Metrics {
    var m = Metrics()
    let n = Double(rankedRelevance.count)
    for r in rankedRelevance {
        if let first = r.firstIndex(of: true) {
            if first < 1 { m.recall1 += 1 }
            if first < 5 { m.recall5 += 1 }
            if first < 10 { m.recall10 += 1 }
            m.mrr10 += 1.0 / Double(first + 1)
        }
    }
    m.recall1 /= n; m.recall5 /= n; m.recall10 /= n; m.mrr10 /= n
    return m
}

func pct(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }
func row(_ label: String, _ m: Metrics) -> String {
    "  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) R@1 \(pct(m.recall1))  R@5 \(pct(m.recall5))  R@10 \(pct(m.recall10))  MRR@10 \(String(format: "%.3f", m.mrr10))"
}

// MARK: - Embedding

func embed(
    _ texts: [String], container: EmbedderModelContainer, spec: ModelSpec, batchSize: Int = 16
) async -> [[Float]] {
    await container.perform { (model: EmbeddingModel, tokenizer: MLXLMCommon.Tokenizer, pooling: Pooling) -> [[Float]] in
        // The tokenizer's own EOS (<|im_end|> for Qwen3) is not the token the model pools on.
        let appended = spec.appendToken.flatMap { tokenizer.convertTokenToId($0) }
        let encoded: [[Int]] = texts.map { text in
            var ids = tokenizer.encode(text: text, addSpecialTokens: true)
            if ids.count > spec.maxTokens { ids = Array(ids.prefix(spec.maxTokens - (appended != nil ? 1 : 0))) }
            if let appended, ids.last != appended { ids.append(appended) }
            return ids
        }
        // Sort by length so batches pad as little as possible; restore order at the end.
        let order = encoded.indices.sorted { encoded[$0].count < encoded[$1].count }
        var out = [[Float]](repeating: [], count: texts.count)
        var start = 0
        while start < order.count {
            let idx = Array(order[start..<min(start + batchSize, order.count)])
            start += batchSize
            let width = idx.map { encoded[$0].count }.max() ?? 1
            var tokens = [Int32](), maskInts = [Int32]()
            for i in idx {
                let ids = encoded[i]
                tokens += ids.map(Int32.init) + [Int32](repeating: 0, count: width - ids.count)
                maskInts += [Int32](repeating: 1, count: ids.count) + [Int32](repeating: 0, count: width - ids.count)
            }
            let padded = MLXArray(tokens, [idx.count, width])
            let mask = MLXArray(maskInts, [idx.count, width]) .> 0
            let tokenTypes = MLXArray.zeros(like: padded)
            let pooled = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                mask: mask, normalize: true, applyLayerNorm: spec.layerNorm)
            pooled.eval()
            for (row, i) in idx.enumerated() {
                out[i] = pooled[row].asArray(Float.self)
            }
        }
        return out
    }
}

// MARK: - Workaround for rotary-only checkpoints

/// Symlinked copy of a model directory whose config.json has `max_position_embeddings: 0`, which
/// stops the library from creating a learned-position table the checkpoint doesn't contain.
func patchedCopy(of dir: URL, in tmp: URL) throws -> URL {
    let out = tmp.appendingPathComponent("patched_" + dir.lastPathComponent)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name != "config.json" {
        try FileManager.default.createSymbolicLink(
            at: out.appendingPathComponent(name), withDestinationURL: dir.appendingPathComponent(name))
    }
    let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
    var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    config["max_position_embeddings"] = 0
    try JSONSerialization.data(withJSONObject: config).write(to: out.appendingPathComponent("config.json"))
    return out
}

// MARK: - LocalEmbedder self-test (real model; cannot run under `swift test`, see LocalEmbedderTests)

func selfTest(sourceDir: URL) async throws -> Bool {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("  \(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    print("[LocalEmbedder self-test] NLEmbedding through the production provider")
    let e = LocalEmbedder()
    check(await e.isInstalled, "model installed natively")

    let docs = try await e.embed([
        "actor InferenceScheduler serialises GPU work with priorities",
        "func drawBackground(in rect: CGRect) fills the view with a gradient",
    ])
    check(docs.count == 2 && docs.allSatisfy { $0.count == 512 }, "two 512-dimensional vectors")
    check(docs.allSatisfy { abs($0.reduce(0) { $0 + $1 * $1 }.squareRoot() - 1) < 1e-3 }, "vectors are unit length")
    check(await e.healthCheck() == .healthy, "health after load is healthy")

    let q = try await e.embedQuery("queue that orders GPU jobs by priority")
    check(dot(q, docs[0]) > dot(q, docs[1]), "related document ranks above unrelated (\(String(format: "%.3f", dot(q, docs[0]))) vs \(String(format: "%.3f", dot(q, docs[1]))))")
    let plain = try await e.embed(["queue that orders GPU jobs by priority"])
    check(dot(q, plain[0]) < 0.9999, "query prefix changes the vector")
    let again = try await e.embed(["actor InferenceScheduler serialises GPU work with priorities"])
    check(dot(again[0], docs[0]) > 0.9999, "embedding is deterministic and batch-size independent")

    // Ordering is preserved through length-sorted batching.
    let mixed = ["short", String(repeating: "a much longer sentence about schedulers ", count: 30), "mid length text here"]
    let together = try await e.embed(mixed)
    var separate: [[Float]] = []
    for t in mixed { separate.append(try await e.embed([t])[0]) }
    check(zip(together, separate).allSatisfy { dot($0, $1) > 0.999 }, "results come back in input order")


    // End to end, offline: index the repo through the real pipeline with ONLY the local embedder
    // registered (no cloud provider anywhere), then answer the eval questions with `search`.
    print("[offline code search end to end] IndexingPipeline + LocalEmbedder + VectorStore, no cloud provider")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("selftest_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let registry = ModelRegistry()
    await registry.register(e)
    let store = VectorStore(dbURL: tmp.appendingPathComponent("index.sqlite"), embeddingDimension: e.dimension)
    let pipeline = IndexingPipeline(store: store, registry: registry)
    try await pipeline.open()
    let t0 = Date()
    let files = swiftFiles(in: sourceDir)
    for f in files { try await pipeline.index(fileURL: f) }
    print("  indexed \(files.count) files in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    var relevance: [[Bool]] = []
    for q in evalSet {
        let hits = try await pipeline.search(query: q.text, topK: 10)
        relevance.append(hits.map { isRelevant(q, path: $0.filePath, content: $0.content) })
    }
    let m = metrics(relevance)
    print(row("pipeline.search", m))
    check(m.recall10 >= 0.85, "recall@10 ≥ 85% (\(pct(m.recall10)))")
    check(m.mrr10 >= 0.60, "MRR@10 ≥ 0.60 (\(String(format: "%.3f", m.mrr10)))")
    try await store.close()

    print(failures == 0 ? "  all checks passed" : "  \(failures) FAILED")
    return failures == 0
}

// MARK: - Run

struct ModelResult: Codable {
    var key: String
    var dimension: Int
    var loadSeconds: Double
    var embedChunksPerSecond: Double
    var peakGPUBytes: Int
    var dense: Metrics
    var hybrid: Metrics
}

func run(_ opts: Options) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    if opts.selfTest { exit(try await selfTest(sourceDir: opts.sourceDir) ? 0 : 1) }
    let chunks = try await loadCorpus(sourceDir: opts.sourceDir)
    print("corpus: \(chunks.count) chunks from \(Set(chunks.map(\.filePath)).count) files; \(evalSet.count) queries")

    // Ground truth must exist, or the metric silently penalises every retriever.
    var relevantCounts: [Int] = []
    for q in evalSet {
        let n = chunks.filter { isRelevant(q, path: $0.filePath, content: $0.content) }.count
        relevantCounts.append(n)
        if n == 0 { print("  ⚠︎ no chunk matches ground truth for: \(q.text)  [\(q.file) / \(q.marker)]") }
    }
    let usable = evalSet.indices.filter { relevantCounts[$0] > 0 }
    let queries = usable.map { evalSet[$0] }
    print("queries with ground truth: \(queries.count)/\(evalSet.count)\n")

    if let dump = opts.dumpCorpus {
        let payload = try JSONSerialization.data(withJSONObject: [
            "chunks": chunks.map { ["path": $0.filePath, "content": $0.content] },
            "queries": queries.map { ["text": $0.text, "file": $0.file, "marker": $0.marker] },
        ])
        try payload.write(to: dump)
        print("dumped corpus to \(dump.path)\n")
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("embed_bench_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // BM25 baseline through the real store (no embeddings stored → dense side is empty).
    let bm25Store = VectorStore(dbURL: tmp.appendingPathComponent("bm25.sqlite"), embeddingDimension: 8)
    try await bm25Store.open()
    try await bm25Store.upsertChunks(chunks)
    var bm25Rel: [[Bool]] = []
    for q in queries {
        let hits = try await bm25Store.hybridSearch(query: q.text, queryEmbedding: [], topK: 10)
        bm25Rel.append(hits.map { isRelevant(q, path: $0.filePath, content: $0.content) })
    }
    print("results (higher is better):")
    print(row("BM25 (FTS5, fixed)", metrics(bm25Rel)))

    var results: [ModelResult] = []
    let docs = chunks.map { "File: \(URL(fileURLWithPath: $0.filePath).lastPathComponent) (\($0.declarationKind))\n\($0.content)" }

    for spec in modelSpecs where opts.wanted.contains(spec.key) {
        let dir = embedderRoot.appendingPathComponent(spec.directory)
        guard FileManager.default.fileExists(atPath: dir.path) else { print("  \(spec.key): model directory missing, skipped"); continue }

        Memory.peakMemory = 0
        let t0 = Date()
        let loadDir = spec.dropLearnedPositions ? try patchedCopy(of: dir, in: tmp) : dir
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: loadDir, using: TransformersTokenizerLoader())
        let loadSeconds = Date().timeIntervalSince(t0)

        let t1 = Date()
        let docVectors = await embed(docs.map { spec.documentPrefix + $0 }, container: container, spec: spec)
        let embedSeconds = Date().timeIntervalSince(t1)
        let queryVectors = await embed(queries.map { spec.queryPrefix + $0.text }, container: container, spec: spec)
        let peak = Memory.peakMemory
        let dim = docVectors.first?.count ?? 0

        // Dense-only: brute-force cosine (vectors are L2-normalised).
        var denseRel: [[Bool]] = []
        for (qi, q) in queries.enumerated() {
            let qv = queryVectors[qi]
            let scored = docVectors.enumerated().map { (i, dv) -> (Int, Float) in
                var s: Float = 0
                for k in 0..<min(dv.count, qv.count) { s += dv[k] * qv[k] }
                return (i, s)
            }.sorted { $0.1 > $1.1 }.prefix(10)
            denseRel.append(scored.map { isRelevant(q, path: chunks[$0.0].filePath, content: chunks[$0.0].content) })
        }

        // Hybrid through the production store (sqlite-vec + FTS5 + RRF k=60).
        let store = VectorStore(dbURL: tmp.appendingPathComponent("\(spec.key).sqlite"), embeddingDimension: dim)
        try await store.open()
        try await store.upsertChunks(chunks)
        for (i, c) in chunks.enumerated() { try await store.storeEmbedding(docVectors[i], for: c.id, contentHash: c.contentHash) }
        var hybridRel: [[Bool]] = []
        for (qi, q) in queries.enumerated() {
            let hits = try await store.hybridSearch(query: q.text, queryEmbedding: queryVectors[qi], topK: 10)
            hybridRel.append(hits.map { isRelevant(q, path: $0.filePath, content: $0.content) })
        }

        let r = ModelResult(key: spec.key, dimension: dim, loadSeconds: loadSeconds,
                            embedChunksPerSecond: Double(chunks.count) / embedSeconds, peakGPUBytes: peak,
                            dense: metrics(denseRel), hybrid: metrics(hybridRel))
        results.append(r)
        print(row("\(spec.key) dense", r.dense))
        print(row("\(spec.key) + BM25 hybrid", r.hybrid))
        print("    \(spec.key): dim \(dim) · load \(String(format: "%.1f", loadSeconds)) s · embed \(String(format: "%.0f", r.embedChunksPerSecond)) chunks/s (\(chunks.count) chunks in \(String(format: "%.1f", embedSeconds)) s) · peak GPU \(String(format: "%.2f", Double(peak) / 1_073_741_824)) GiB")
        try await store.close()
        Memory.clearCache()
    }

    if let url = opts.jsonOut {
        struct Report: Codable { var chunks: Int; var queries: Int; var bm25: Metrics; var models: [ModelResult] }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Report(chunks: chunks.count, queries: queries.count, bm25: metrics(bm25Rel), models: results)).write(to: url)
        print("\nwrote \(url.path)")
    }
    try await bm25Store.close()
}

do { try await run(Options.parse(CommandLine.arguments)) } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
