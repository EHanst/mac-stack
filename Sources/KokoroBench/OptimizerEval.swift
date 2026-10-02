import Foundation
import MLX
import MLXRandom
import StackCore

/// Quality gate for a local model doing prompt rewrites: runs a fixed set of literal-heavy drafts
/// through the production request (`PromptOptimizer.requestMessages`, the model's default sampling)
/// and the production acceptance checks (`PromptOptimizer.result`), then tallies what got through.
enum OptimizerEval {
    static let drafts: [(name: String, text: String)] = [
        ("crash-path", "fix the crash in `loadItems()` in Sources/App/Loader.swift when the list is empty"),
        ("retry-numbers", "add a retry to the upload call, use the \"retry limit\" setting, default 30 seconds and at most 5 tries, keep fetchAll_v2 as is"),
        ("code-fence", "why does this not compile?\n```swift\nlet items: [Int] = try await load()\nfor i in items { print(i) }\n```\nit says 'async call in a function that does not support concurrency'"),
        ("vague", "make the app faster"),
        ("conflict", "Keep the answer short. Explain everything in great detail with lots of examples. Don't use any code."),
        ("migration", "Write a migration that adds `users.last_seen_at` (timestamptz, default now()), backfill in batches of 5000 rows, and never hold a lock longer than 2s. Postgres 15."),
        ("refactor-paths", "split Sources/App/Store.swift into Store+Load.swift and Store+Save.swift, no behaviour change, update the imports in Sources/App/Views/ListView.swift"),
        ("short", "add dark mode"),
        ("versions-url", "upgrade swift-nio to 2.65.0 in Package.swift, see https://github.com/apple/swift-nio/releases and fix what breaks"),
        ("already-clear", "Rename the property `title` to `heading` on `Note` in Sources/Model/Note.swift and update every call site. Do not change behaviour. Build must pass."),
        // Added to widen the set: prose-only, code-heavy, numeric, multi-step and error-log drafts.
        ("flaky-test", "the test `testSyncRetries` in Tests/SyncTests.swift fails about one run in ten on CI, find out why and make it stable without adding sleeps"),
        ("sql-index", "queries on orders filtered by customer_id and created_at take 4s on 20M rows, add the right index in db/migrations and show the EXPLAIN before and after"),
        ("python-cli", "write a CLI in scripts/prune_logs.py that deletes *.log files older than 14 days under /var/log/myapp, dry run by default, --apply to delete, exit 1 if anything fails"),
        ("css-layout", "the sidebar in src/components/Sidebar.tsx overlaps the main content below 768px, fix it with CSS only, no new dependencies"),
        ("error-log", "app crashes on launch with `Fatal error: Unexpectedly found nil while unwrapping an Optional value` at AppDelegate.swift:42 after the 3.2.0 update, find the cause"),
        ("api-design", "add pagination to GET /v1/orders: cursor based, default page size 50, max 200, return next_cursor, keep the response shape otherwise identical"),
        ("perf", "the image grid in GalleryView scrolls at 20 fps on an iPhone 12, get it to 60 fps without lowering image quality"),
        ("docs", "write a README section for contributors: how to run `swift test`, how to run the benchmark, and where the architecture notes are in ARCHITECTURE.md"),
        ("regex", "write a regex that matches ISO 8601 dates like 2024-03-09 but rejects 2024-13-40, and explain each part"),
        ("review", "review the diff in PR 482 for race conditions in `TokenCache` and call out anything that is not Sendable"),
        ("rename-sweep", "rename the module `Core` to `StackCore` in Package.swift, every import Core line and the test target, then make sure `swift build` still passes"),
        ("tone", "reply to the customer who says the export button lost their data, apologise once, ask for the file name and time, do not promise a fix date"),
        ("shell", "write a zsh one-liner that finds the 10 largest files under ~/Downloads modified in the last 30 days and prints size in MB and path"),
        ("terse", "tests failing"),
    ]

    static func mode(_ name: String) -> OptimizeMode? {
        ["improve": .improve, "expand": .expand, "adapt": .adapt][name]
    }

    static func run(provider: LocalMLXProvider, modes: [String], repeats: Int, json: URL?, sampling: String, repair: Bool, profile: String = "local", modelName: String = "") async {
        // The same per-model tuning production picks for this model; EVAL_TUNING=standard measures the baseline.
        let tuning = ProcessInfo.processInfo.environment["EVAL_TUNING"] == "standard"
            ? OptimizerTuning.standard : OptimizerTuning.forModel("local:" + modelName)
        let params: SamplingParameters? = switch sampling {
        case "greedy": .greedy
        case "chat": .bonsaiInstruct
        default: tuning.sampling   // what the optimizer uses
        }
        let target: ModelPromptProfile = switch profile {
        case "claude": .claude
        case "claudecode": .claudeCode
        case "gpt": .gpt
        case "gemini": .gemini
        case "reasoning": .reasoning
        case "deepseek": .deepseekR1
        case "generic": .generic
        default: .localSmall
        }
        let context = OptimizeContext(profile: target, tuning: tuning)
        var rows: [[String: Any]] = []
        var specCycles = 0, specAccepted = 0, novelTotal = 0
        defer { print("  novel literals in accepted rewrites: \(novelTotal)") }
        defer { if specCycles > 0 { print("  draft acceptance: \(specAccepted * 100 / specCycles)% over \(specCycles) cycles") } }
        var tally: [String: [String: Int]] = [:]
        print("[optimizer eval] sampling=\(sampling) · \(drafts.count) drafts × modes \(modes.joined(separator: ",")) × \(repeats) run(s)")
        for modeName in modes {
            guard let m = mode(modeName) else { print("  unknown mode \(modeName)"); continue }
            for (name, text) in drafts {
                for run in 0..<repeats {
                    let messages = PromptOptimizer.requestMessages(draft: text, context: context, mode: m, useSharedPrefix: false)
                    await provider.clearPromptCache()
                    var tokens = 0
                    let start = Date()
                    func pass(_ messages: [Message]) async -> String {
                        var raw = ""
                        do {
                            for try await e in await provider.generate(
                                messages: messages, tools: [],
                                options: GenerationOptions(maxTokens: min(8_000, tuning.replyCap[m] ?? 8_000), sampling: params, cacheSnapshots: false)) {
                                if case .token(let t) = e { raw += t; tokens += 1 }
                            }
                        } catch { print("    generation error: \(error)"); raw = "" }
                        return raw
                    }
                    // Same shortcuts as `PromptOptimizer.optimize`: no generation for an already-clear draft.
                    let skipped = m == .improve && PromptLint.isAlreadyClear(text)
                    var raw = skipped ? "" : await pass(messages)
                    var r = PromptOptimizer.result(raw: skipped ? "<improved>\(text)</improved>" : raw, original: text, mode: m,
                                                   model: "local:eval", ceiling: 8_000)
                    var restored = false
                    if r.rejection?.missing.isEmpty == false {
                        let patched = PromptOptimizer.restoringLiterals(raw: raw, original: text)
                        if patched != raw {
                            raw = patched
                            r = PromptOptimizer.result(raw: raw, original: text, mode: m, model: "local:eval", ceiling: 8_000)
                            restored = r.rejection == nil
                        }
                    }
                    var repaired = false
                    if repair, let missing = r.rejection?.missing, !missing.isEmpty {
                        let second = await pass(PromptOptimizer.repairMessages(messages, reply: raw, missing: missing))
                        let retried = PromptOptimizer.result(raw: second, original: text, mode: m, model: "local:eval", ceiling: 8_000)
                        if retried.rejection == nil { r = retried; raw = second; repaired = true }
                    }
                    let secs = Date().timeIntervalSince(start)
                    if let spec = await provider.lastSpeculationForBench(), spec.cycles > 0 {
                        specCycles += spec.cycles; specAccepted += spec.accepted
                    }
                    if ProcessInfo.processInfo.environment["EVAL_MEM"] != nil {
                        let b = await provider.budgetInputs()
                        func g(_ x: Int) -> String { String(format: "%.2f", Double(x) / 1_073_741_824) }
                        print("    mem: ws \(g(b.workingSet)) weights \(g(b.weights)) active \(g(b.active)) cache \(g(b.cache)) avail \(g(b.available)) → \(await provider.contextVerdict())")
                    }
                    // Literals the rewrite introduced that the draft never had: a count of invention, not a gate.
                    let novel = r.rejection == nil ? PromptLiterals.invented(in: r.improved, from: text) : []
                    novelTotal += novel.count
                    let outcome: String
                    if let rej = r.rejection {
                        outcome = rej.missing.isEmpty ? "rejected:\(rej.reason.prefix(40))" : "rejected:dropped-literal"
                    } else if !r.questions.isEmpty && r.improved == r.original { outcome = "questions-only" }
                    else if r.didChange { outcome = repaired ? "accepted-after-repair" : restored ? "accepted-after-restore" : "accepted" }
                    else { outcome = skipped ? "skipped-clear" : "unchanged" }
                    tally[modeName, default: [:]][outcome, default: 0] += 1
                    let cut = raw.contains("<improved>") && !raw.contains("</improved>")
                    if cut { tally[modeName, default: [:]]["cut-off", default: 0] += 1 }
                    print("  \(modeName) · \(name)#\(run): \(outcome)\(cut ? " (cut off)" : "") · \(tokens) tok · \(String(format: "%.1f", secs)) s"
                          + (r.rejection?.missing.isEmpty == false ? " · missing \(r.rejection!.missing)" : ""))
                    rows.append(["mode": modeName, "draft": name, "outcome": outcome, "tokens": tokens, "seconds": secs,
                                 "missing": r.rejection?.missing ?? [], "novel": novel, "improved": r.improved, "changes": r.changes,
                                 "questions": r.questions, "raw": raw])
                }
            }
        }
        print("\n[optimizer eval summary]")
        for (modeName, counts) in tally.sorted(by: { $0.key < $1.key }) {
            let total = counts.filter { $0.key != "cut-off" }.values.reduce(0, +)
            print("  \(modeName): " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)/\(total)" }.joined(separator: " · "))
        }
        if let json, let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) {
            try? data.write(to: json)
            print("  wrote \(json.path)")
        }
    }
}

enum SamplerBench {
    static func run() {
        let v = 248_320
        let logits = MLXRandom.normal([1, v]) * 3
        let seen = MLXArray.zeros([1, v])
        MLX.eval(logits, seen)
        func time(_ name: String, _ f: () -> [MLXArray]) {
            for _ in 0..<3 { MLX.eval(f()) }
            let n = 30
            let t = Date()
            for _ in 0..<n { MLX.eval(f()) }
            print(String(format: "  %-28@ %.2f ms", name as NSString, Date().timeIntervalSince(t) * 1000 / Double(n)))
        }
        let p = SamplingParameters.bonsaiInstruct
        time("argMax") { [argMax(logits, axis: -1)] }
        time("top(k=20) values") { [top(logits, k: 20, axis: -1)] }
        time("argPartition(k=20)") { [argPartition(-logits, kth: 19, axis: -1)] }
        time("penalty only") { [logits - 1.5 * seen] }
        time("full sample (chat)") { [TokenSampler.sample(logits, p, seen: seen)] }
        time("full sample (no penalty)") { [TokenSampler.sample(logits, SamplingParameters(temperature: 0.7, topK: 20, topP: 0.8), seen: nil)] }
        let tok = MLXArray([Int32(5)])
        time("oneHot") { [TokenSampler.oneHot(tok, vocab: v)] }
    }
}
