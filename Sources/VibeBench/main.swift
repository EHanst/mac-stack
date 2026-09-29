import Darwin
import Foundation
import MLX
import VibeCockpitCore

// vibe-bench — performance harness for the local model.
//   swift run -c release VibeBench [--model DIR] [--contexts 512,4096,16384] [--gen 128]
//                                  [--runs 3] [--json out.json]
// Reports load time, TTFT, prefill/decode tokens per second and memory per context size.

struct Options {
    var model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VibeCockpit/Models/Bonsai-27B")
    var contexts = [512, 4096, 16384]
    var gen = 128
    var runs = 3
    var json: URL?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--model": if let v = it.next() { model = URL(fileURLWithPath: v) }
            case "--contexts": if let v = it.next() { contexts = v.split(separator: ",").compactMap { Int($0) } }
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
    var results: [ContextResult]
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
    while s.count < tokens * 4 {   // ≈ 4 characters per token for English text
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

func run() async throws {
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so `> log` shows progress live
    let opts = Options(CommandLine.arguments)
    let info = ProcessInfo.processInfo
    print("VibeBench  \(sysctlString("machdep.cpu.brand_string"))  \(gb(Int(info.physicalMemory)))  macOS \(info.operatingSystemVersionString)")
    print("model: \(opts.model.path)")
    print("thermal: \(info.thermalState.rawValue)  lowPower: \(info.isLowPowerModeEnabled)\n")

    let provider = LocalMLXProvider(id: "local:bench", modelDirectory: opts.model)
    print("loading model…")
    let loadStart = Date()
    try await provider.warmUp()
    let loadSeconds = Date().timeIntervalSince(loadStart)
    let rssLoaded = residentBytes()
    print("load: \(fmt(loadSeconds, 2)) s   RSS after load: \(gb(rssLoaded))\n")

    print("warm-up generation…")
    // Warm-up generation: compiles kernels so the first measured run isn't an outlier.
    for try await _ in await provider.generate(
        messages: [Message(role: .user, content: "Say hi.")], tools: [],
        options: GenerationOptions(maxTokens: 16)) {}

    var results: [ContextResult] = []
    print("ctx      TTFT s   prefill tok/s   decode tok/s   peak GPU     RSS")
    for target in opts.contexts {
        print("measuring ~\(target) tokens…")
        var samples: [Sample] = []
        for run in 0..<opts.runs {
            Memory.peakMemory = 0
            let prompt = makePrompt(tokens: target, nonce: run)
            let start = Date()
            var ttft: Double?
            for try await event in await provider.generate(
                messages: [Message(role: .user, content: prompt)], tools: [],
                options: GenerationOptions(maxTokens: opts.gen, temperature: 0)) {
                if case .token = event, ttft == nil { ttft = Date().timeIntervalSince(start) }
            }
            guard let stats = await provider.lastStats else { continue }
            samples.append(Sample(ttftSeconds: ttft ?? .nan, stats: stats, rssBytes: residentBytes()))
        }
        results.append(ContextResult(targetTokens: target, samples: samples))
        guard !samples.isEmpty else { print("\(target)  no samples"); continue }
        let actual = samples[0].stats.promptTokens
        print("\(String(actual).padding(toLength: 8, withPad: " ", startingAt: 0)) "
              + "\(fmt(median(samples.map(\.ttftSeconds)), 2).padding(toLength: 8, withPad: " ", startingAt: 0)) "
              + "\(fmt(median(samples.map(\.stats.prefillTokensPerSecond))).padding(toLength: 15, withPad: " ", startingAt: 0)) "
              + "\(fmt(median(samples.map(\.stats.decodeTokensPerSecond))).padding(toLength: 14, withPad: " ", startingAt: 0)) "
              + "\(gb(samples.map(\.stats.peakGPUBytes).max() ?? 0).padding(toLength: 12, withPad: " ", startingAt: 0)) "
              + gb(samples.map(\.rssBytes).max() ?? 0))
    }

    if let url = opts.json {
        let report = Report(
            date: Date(), chip: sysctlString("machdep.cpu.brand_string"),
            physicalMemoryBytes: Int(info.physicalMemory), macOS: info.operatingSystemVersionString,
            lowPowerMode: info.isLowPowerModeEnabled, thermalStateAtStart: info.thermalState.rawValue,
            model: opts.model.lastPathComponent, loadSeconds: loadSeconds, rssAfterLoadBytes: rssLoaded,
            results: results)
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
