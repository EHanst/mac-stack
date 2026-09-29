import Darwin
import Foundation
import MLX
import MLXRandom
import StackCore

// vibe-bench — performance harness for the local model.
//   swift run -c release VibeBench [--model DIR] [--contexts 512,4096] [--gen 128] [--runs 3]
//                                  [--warm-prefix 4096] [--no-matmul] [--timeout 300] [--json out.json]
//                                  [--sweep 1024,2048,4096,8192 --chunks 512,256]   (memory profile)
// Reports load time, TTFT, prefill/decode tokens per second and memory per context size, a
// warm-prefix (prefix-cache) case, and a matmul micro-benchmark at M=512 for the compute ceiling.
// `--contexts none` / `--warm-prefix 0` skip those sections. Every generation has a watchdog
// (`--timeout` seconds) so a stuck run is recorded instead of hanging the harness.

struct Options {
    var model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VibeCockpit/Models/Bonsai-27B")
    var contexts = [512, 4096]
    var warmPrefix = 4096
    var matmul = true
    var sweep: [Int] = []
    var guardTest = false
    var serviceTest = false
    var chunks = [512]
    var timeout = 300.0
    var gen = 128
    var runs = 3
    var json: URL?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--model": if let v = it.next() { model = URL(fileURLWithPath: v) }
            case "--contexts": if let v = it.next() { contexts = v.split(separator: ",").compactMap { Int($0) } }
            case "--warm-prefix": if let v = it.next(), let n = Int(v) { warmPrefix = max(0, n) }
            case "--no-matmul": matmul = false
            case "--guard-test": guardTest = true
            case "--service-test": serviceTest = true
            case "--sweep": if let v = it.next() { sweep = v.split(separator: ",").compactMap { Int($0) } }
            case "--chunks": if let v = it.next() { chunks = v.split(separator: ",").compactMap { Int($0) } }
            case "--timeout": if let v = it.next(), let n = Double(v) { timeout = max(1, n) }
            case "--gen": if let v = it.next(), let n = Int(v) { gen = n }
            case "--runs": if let v = it.next(), let n = Int(v) { runs = max(1, n) }
            case "--json": if let v = it.next() { json = URL(fileURLWithPath: v) }
            default: FileHandle.standardError.write(Data("ignored argument: \(a)\n".utf8))
            }
        }
    }
}

struct Sample: Codable {
    var ttftSeconds: Double
    var stats: GenerationStats
    var rssBytes: Int
}

struct ContextResult: Codable {
    var targetTokens: Int
    var samples: [Sample]
}

struct WarmStep: Codable {
    var label: String
    var ttftSeconds: Double
    var stats: GenerationStats?
    var timedOut: Bool
}

struct MatmulResult: Codable {
    var label: String
    var m: Int, k: Int, n: Int
    var tflops: Double
}

struct Report: Codable {
    var date: Date
    var chip: String
    var physicalMemoryBytes: Int
    var macOS: String
    var lowPowerMode: Bool
    var thermalStateAtStart: Int
    var model: String
    var loadSeconds: Double
    var rssAfterLoadBytes: Int
    var maxRecommendedWorkingSetBytes: Int?
    var results: [ContextResult]
    var warmPrefix: [WarmStep]
    var matmul: [MatmulResult]
    var estimatedPrefillCeilingTokPerSec: Double?
}

func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

/// Synthetic prompt of roughly `tokens` tokens. A per-run nonce leads the text so the prefix
/// cache never turns a "cold" measurement into a warm one.
func makePrompt(tokens: Int, nonce: Int) -> String {
    var s = "Run \(nonce)-\(UInt32.random(in: 0...UInt32.max)). Summarise the following notes in one sentence.\n"
    var i = 0
    while s.count < tokens * 3 {   // ≈ 2.9 characters per token measured on this tokenizer
        s += "Note \(i): the quick brown fox \(i * 7 % 13) jumps over the lazy dog near gate \(i % 97).\n"
        i += 1
    }
    return s
}

func fmt(_ v: Double, _ p: Int = 1) -> String { String(format: "%.\(p)f", v) }
func gb(_ b: Int) -> String { fmt(Double(b) / 1_073_741_824, 2) + " GB" }

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// One generation with a watchdog. Returns nil stats + `timedOut` if the deadline passes.
func measure(
    _ provider: LocalMLXProvider, _ messages: [Message], gen: Int, timeout: Double
) async -> (ttft: Double, text: String, stats: GenerationStats?, timedOut: Bool) {
    Memory.peakMemory = 0
    let start = Date()
    let work = Task { () -> (Double, String) in
        var ttft = Double.nan
        var text = ""
        for try await event in await provider.generate(
            messages: messages, tools: [],
            options: GenerationOptions(maxTokens: gen, temperature: 0)) {
            if case .token(let t) = event {
                if ttft.isNaN { ttft = Date().timeIntervalSince(start) }
                text += t
            }
        }
        return (ttft, text)
    }
    let watchdog = Task {
        try await Task.sleep(for: .seconds(timeout))
        work.cancel()
    }
    defer { watchdog.cancel() }
    do {
        let (ttft, text) = try await work.value
        return (ttft, text, await provider.lastStats, false)
    } catch {
        return (.nan, "", nil, true)
    }
}

/// Dense and 2-bit quantized matmul at M=512 (one prefill chunk) using the model's real layer
/// shapes, to bound what prefill can achieve on this GPU.
func matmulBench(hidden: Int, intermediate: Int, bits: Int, groupSize: Int) -> [MatmulResult] {
    let m = 512
    let shapes = [("MLP up/gate", hidden, intermediate), ("MLP down", intermediate, hidden),
                  ("attn proj", hidden, hidden)]
    var out: [MatmulResult] = []
    for (name, k, n) in shapes {
        let x = MLXRandom.normal([m, k]).asType(.bfloat16)
        let w = MLXRandom.normal([n, k]).asType(.bfloat16)
        let (wq, scales, biases) = quantized(w, groupSize: groupSize, bits: bits)
        MLX.eval(x, w, wq, scales)
        if let biases { MLX.eval(biases) }

        func time(_ op: () -> MLXArray) -> Double {
            for _ in 0..<3 { MLX.eval(op()) }        // warm-up
            let iters = 20
            let t0 = Date()
            for _ in 0..<iters { MLX.eval(op()) }
            return Date().timeIntervalSince(t0) / Double(iters)
        }
        let flops = 2.0 * Double(m) * Double(k) * Double(n)
        let dense = time { matmul(x, w.T) }
        let quant = time { quantizedMM(x, wq, scales: scales, biases: biases, transpose: true,
                                       groupSize: groupSize, bits: bits) }
        out.append(MatmulResult(label: "\(name) bf16", m: m, k: k, n: n, tflops: flops / dense / 1e12))
        out.append(MatmulResult(label: "\(name) \(bits)-bit", m: m, k: k, n: n, tflops: flops / quant / 1e12))
    }
    return out
}

func modelDims(_ dir: URL) -> (hidden: Int, intermediate: Int, bits: Int, group: Int)? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let t = (root["text_config"] as? [String: Any]) ?? root
    let q = (root["quantization"] as? [String: Any]) ?? (t["quantization"] as? [String: Any]) ?? [:]
    guard let h = t["hidden_size"] as? Int, let i = t["intermediate_size"] as? Int else { return nil }
    return (h, i, q["bits"] as? Int ?? 2, q["group_size"] as? Int ?? 128)
}

func userMessage(_ text: String) -> Message { Message(role: .user, content: text) }
func generationOptions(_ maxTokens: Int) -> GenerationOptions { GenerationOptions(maxTokens: maxTokens, temperature: 0) }

func run() async throws {
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so `> log` shows progress live
    let opts = Options(CommandLine.arguments)
    let info = ProcessInfo.processInfo
    let workingSet = GPU.maxRecommendedWorkingSetBytes()
    print("VibeBench  \(sysctlString("machdep.cpu.brand_string"))  \(gb(Int(info.physicalMemory)))  macOS \(info.operatingSystemVersionString)")
    print("model: \(opts.model.path)")
    print("GPU recommended working set: \(workingSet.map(gb) ?? "n/a")")
    print("thermal: \(info.thermalState.rawValue)  lowPower: \(info.isLowPowerModeEnabled)  watchdog: \(Int(opts.timeout)) s\n")

    let provider = LocalMLXProvider(id: "local:bench", modelDirectory: opts.model)
    print("loading model…")
    let loadStart = Date()
    try await provider.warmUp()
    let loadSeconds = Date().timeIntervalSince(loadStart)
    let rssLoaded = residentBytes()
    print("load: \(fmt(loadSeconds, 2)) s   RSS after load: \(gb(rssLoaded))\n")

    // Warm-up generation: compiles kernels so the first measured run isn't an outlier.
    print("warm-up generation…")
    _ = await measure(provider, [Message(role: .user, content: "Say hi.")], gen: 16, timeout: opts.timeout)

    func peakText(_ bytes: Int) -> String {
        guard let ws = workingSet, ws > 0 else { return gb(bytes) }
        return "\(gb(bytes)) (\(Int(Double(bytes) / Double(ws) * 100))% of working set)"
    }

    // ── Context budget: this machine, and what other RAM tiers would get ─────────────
    do {
        let budget = await provider.budget
        let weights = await provider.weightBytes
        print("[context budget]  model: \(gb(Int(budget.model.fixedOverheadBytes))) fixed + \(budget.model.bytesPerToken / 1000) KB/token, safety \(Int(budget.safetyFraction * 100))%")
        let v = await provider.contextVerdict()
        print("  this Mac now: \(v)")
        print("  by RAM tier (working set assumed 74% of RAM, as measured on the 18 GB Mac; nothing else running):")
        for ram in [8, 16, 18, 24, 32, 64] {
            let ws = Int(Double(ram) * 0.74 * 1_073_741_824)
            print("    \(ram) GB → \(budget.verdict(workingSetBytes: ws, weightBytes: weights))")
        }
        print("")
    }

    if opts.guardTest {
        let limit = await provider.maxContextTokens() ?? 0
        print("[guard test] limit \(limit) tokens; sending a prompt of ~\(limit + 3000)…")
        let t0 = Date()
        do {
            for try await _ in await provider.generate(
                messages: [Message(role: .user, content: makePrompt(tokens: limit + 3000, nonce: 1))],
                tools: [], options: GenerationOptions(maxTokens: 1)) {}
            print("  UNEXPECTED: oversized prompt was accepted")
        } catch {
            print("  refused in \(fmt(Date().timeIntervalSince(t0), 2)) s: \(error.localizedDescription)")
        }
        print("")
    }

    // ── InferenceService on the real model: serialisation and cancellation ───────────
    if opts.serviceTest {
        print("[service test] routing through InferenceService (localOnly) with the real model")
        let registry = ModelRegistry()
        await registry.register(provider)
        let service = InferenceService(registry: registry, policy: .localOnly)

        // 1. Two concurrent requests must run one after the other.
        let t0 = Date()
        async let a: Double = {
            for try await _ in try await service.generate(messages: [userMessage("Count from 1 to 5.")], tools: [], options: generationOptions(24)) {}
            return Date().timeIntervalSince(t0)
        }()
        async let b: Double = {
            for try await _ in try await service.generate(messages: [userMessage("Name three colours.")], tools: [], options: generationOptions(24)) {}
            return Date().timeIntervalSince(t0)
        }()
        let (ta, tb) = try await (a, b)
        let first = min(ta, tb), second = max(ta, tb)
        print("  concurrent x2: first done at \(fmt(first, 1)) s, second at \(fmt(second, 1)) s  (serialised if second ≈ 2× first: ratio \(fmt(second / first, 2)))")

        // 2. Cancel a long generation after its first token; the next request must not wait for it.
        let longTask = Task { () -> Int in
            var n = 0
            for try await event in try await service.generate(
                messages: [userMessage("Write a long story about a lighthouse.")], tools: [], options: generationOptions(600)) {
                if case .token = event { n += 1; if n == 3 { throw CancellationError() } }
            }
            return n
        }
        _ = try? await longTask.value
        let t1 = Date()
        var firstTokenAfterCancel: Double?
        for try await event in try await service.generate(
            messages: [userMessage("Say hi.")], tools: [], options: generationOptions(8)) {
            if case .token = event, firstTokenAfterCancel == nil { firstTokenAfterCancel = Date().timeIntervalSince(t1) }
        }
        print("  next request first token \(fmt(firstTokenAfterCancel ?? -1, 2)) s after cancelling a 600-token generation (≈55 s if the GPU had not been freed)")
        print("")
    }

    // ── Cold contexts ──────────────────────────────────────────────────────────────
    var results: [ContextResult] = []
    if !opts.contexts.isEmpty {
        print("\n[cold prefill]  ctx | TTFT s | prefill tok/s | decode tok/s | peak GPU | RSS")
    }
    for target in opts.contexts {
        print("measuring ~\(target) tokens…")
        var samples: [Sample] = []
        for run in 0..<opts.runs {
            let m = await measure(provider, [Message(role: .user, content: makePrompt(tokens: target, nonce: run))],
                                  gen: opts.gen, timeout: opts.timeout)
            if m.timedOut { print("  run \(run): TIMED OUT after \(Int(opts.timeout)) s"); break }
            guard let stats = m.stats else { continue }
            samples.append(Sample(ttftSeconds: m.ttft, stats: stats, rssBytes: residentBytes()))
        }
        results.append(ContextResult(targetTokens: target, samples: samples))
        guard !samples.isEmpty else { print("\(target)  no samples"); continue }
        print("  \(samples[0].stats.promptTokens) tok | TTFT \(fmt(median(samples.map(\.ttftSeconds)), 2)) s"
              + " | prefill \(fmt(median(samples.map(\.stats.prefillTokensPerSecond)))) tok/s"
              + " | decode \(fmt(median(samples.map(\.stats.decodeTokensPerSecond)))) tok/s"
              + " | peak \(peakText(samples.map(\.stats.peakGPUBytes).max() ?? 0))"
              + " | RSS \(gb(samples.map(\.rssBytes).max() ?? 0))")
    }

    // ── Memory sweep: peak GPU vs context length and prefill chunk size ───────────
    if !opts.sweep.isEmpty {
        let weights = await provider.weightBytes
        print("\n[memory sweep]  weights \(gb(weights))  working set \(workingSet.map(gb) ?? "n/a")")
        print("chunk | prompt tok | TTFT s | prefill tok/s | peak GPU | over weights | % working set")
        for chunk in opts.chunks {
            var t = await provider.tuning
            t.prefillChunkSize = chunk
            await provider.setTuning(t)
            for target in opts.sweep {
                await provider.clearPromptCache()   // isolate rows: no memory carried over from earlier prompts
                Memory.clearCache()
                let m = await measure(provider, [Message(role: .user, content: makePrompt(tokens: target, nonce: 7_000 + target))],
                                      gen: 1, timeout: opts.timeout)
                if m.timedOut { print("\(chunk) | ~\(target) | TIMED OUT after \(Int(opts.timeout)) s — stopping this chunk size"); break }
                guard let st = m.stats else { continue }
                let pct = workingSet.map { Int(Double(st.peakGPUBytes) / Double($0) * 100) } ?? 0
                print("\(chunk) | \(st.promptTokens) | \(fmt(m.ttft, 1)) | \(fmt(st.prefillTokensPerSecond)) | \(gb(st.peakGPUBytes)) | +\(gb(st.peakGPUBytes - weights)) | \(pct)%")
                if let ws = workingSet, st.peakGPUBytes > ws { print("  peak exceeded the working set — stopping this chunk size"); break }
            }
        }
    }

    // ── Warm prefix: does the cache actually save prefill? ─────────────────────────
    var warm: [WarmStep] = []
    if opts.warmPrefix > 0 {
        print("\n[warm prefix ~\(opts.warmPrefix) tok]")
        let system = Message(role: .system, content: makePrompt(tokens: opts.warmPrefix, nonce: 9_000))
        let q0 = Message(role: .user, content: "Question A: which note number mentions gate 5?")

        func step(_ label: String, _ messages: [Message]) async -> String {
            let m = await measure(provider, messages, gen: opts.gen, timeout: opts.timeout)
            warm.append(WarmStep(label: label, ttftSeconds: m.ttft, stats: m.stats, timedOut: m.timedOut))
            if m.timedOut { print("  \(label): TIMED OUT after \(Int(opts.timeout)) s"); return "" }
            if let st = m.stats {
                print("  \(label): TTFT \(fmt(m.ttft, 2)) s | prompt \(st.promptTokens) tok, cached \(st.cachedTokens),"
                      + " prefilled \(st.prefilledTokens) | peak \(peakText(st.peakGPUBytes))")
            }
            return m.text
        }
        let a0 = await step("1 cold          ", [system, q0])
        let follow = [system, q0, Message(role: .assistant, content: a0),
                      Message(role: .user, content: "Question B: and which mentions gate 6?")]
        _ = await step("2 follow-up turn", follow)
        _ = await step("3 same again    ", follow)                      // exact repeat (tail snapshot)
        _ = await step("4 new session, same system prompt",
                       [system, Message(role: .user, content: "Question C: list the first three notes.")])
    }

    // ── Compute ceiling ────────────────────────────────────────────────────────────
    var mm: [MatmulResult] = []
    var ceiling: Double?
    if opts.matmul, let dims = modelDims(opts.model) {
        print("\n[matmul micro-benchmark, M=512, model layer shapes]")
        mm = matmulBench(hidden: dims.hidden, intermediate: dims.intermediate, bits: dims.bits, groupSize: dims.group)
        for r in mm { print("  \(r.label.padding(toLength: 22, withPad: " ", startingAt: 0)) [\(r.m)x\(r.k)]·[\(r.k)x\(r.n)]  \(fmt(r.tflops, 2)) TFLOPS") }
        // Prefill costs ≈ 2 FLOPs per weight per token; the model name says 27B parameters.
        let quantRates = mm.filter { $0.label.hasSuffix("-bit") }.map(\.tflops)
        if let best = quantRates.max() {
            ceiling = best * 1e12 / (2 * 27e9)
            print("  → if prefill ran at the best quantized rate (\(fmt(best, 2)) TFLOPS): ≈ \(fmt(ceiling!, 0)) tok/s"
                  + " (assumes 27B params, ignores attention)")
        }
    }

    if let url = opts.json {
        let report = Report(
            date: Date(), chip: sysctlString("machdep.cpu.brand_string"),
            physicalMemoryBytes: Int(info.physicalMemory), macOS: info.operatingSystemVersionString,
            lowPowerMode: info.isLowPowerModeEnabled, thermalStateAtStart: info.thermalState.rawValue,
            model: opts.model.lastPathComponent, loadSeconds: loadSeconds, rssAfterLoadBytes: rssLoaded,
            maxRecommendedWorkingSetBytes: workingSet, results: results, warmPrefix: warm,
            matmul: mm, estimatedPrefillCeilingTokPerSec: ceiling)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(report).write(to: url)
        print("\nwrote \(url.path)")
    }
}

do { try await run() } catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
