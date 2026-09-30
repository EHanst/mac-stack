import Foundation
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
    ]

    static func mode(_ name: String) -> OptimizeMode? {
        ["improve": .improve, "expand": .expand, "adapt": .adapt, "synthesize": .synthesize][name]
    }

    static func run(provider: LocalMLXProvider, modes: [String], repeats: Int, json: URL?, sampling: String, repair: Bool) async {
        let params: SamplingParameters? = switch sampling {
        case "greedy": .greedy
        case "chat": .bonsaiInstruct
        default: .rewrite   // what the optimizer uses
        }
        let context = OptimizeContext(profile: .localSmall)
        var rows: [[String: Any]] = []
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
                                options: GenerationOptions(maxTokens: PromptOptimizer.outputCap(mode: m, servedLocally: true), sampling: params, cacheSnapshots: false)) {
                                if case .token(let t) = e { raw += t; tokens += 1 }
                            }
                        } catch { print("    generation error: \(error)"); raw = "" }
                        return raw
                    }
                    var raw = await pass(messages)
                    var r = PromptOptimizer.result(raw: raw, original: text, mode: m, model: "local:eval", ceiling: 8_000)
                    var repaired = false
                    if repair, let missing = r.rejection?.missing, !missing.isEmpty {
                        let second = await pass(PromptOptimizer.repairMessages(messages, reply: raw, missing: missing))
                        let retried = PromptOptimizer.result(raw: second, original: text, mode: m, model: "local:eval", ceiling: 8_000)
                        if retried.rejection == nil { r = retried; raw = second; repaired = true }
                    }
                    let secs = Date().timeIntervalSince(start)
                    if ProcessInfo.processInfo.environment["EVAL_MEM"] != nil {
                        let b = await provider.budgetInputs()
                        func g(_ x: Int) -> String { String(format: "%.2f", Double(x) / 1_073_741_824) }
                        print("    mem: ws \(g(b.workingSet)) weights \(g(b.weights)) active \(g(b.active)) cache \(g(b.cache)) avail \(g(b.available)) → \(await provider.contextVerdict())")
                    }
                    let outcome: String
                    if let rej = r.rejection {
                        outcome = rej.missing.isEmpty ? "rejected:\(rej.reason.prefix(40))" : "rejected:dropped-literal"
                    } else if !r.questions.isEmpty && r.improved == r.original { outcome = "questions-only" }
                    else if r.didChange { outcome = repaired ? "accepted-after-repair" : "accepted" } else { outcome = "unchanged" }
                    tally[modeName, default: [:]][outcome, default: 0] += 1
                    let cut = raw.contains("<improved>") && !raw.contains("</improved>")
                    if cut { tally[modeName, default: [:]]["cut-off", default: 0] += 1 }
                    print("  \(modeName) · \(name)#\(run): \(outcome)\(cut ? " (cut off)" : "") · \(tokens) tok · \(String(format: "%.1f", secs)) s"
                          + (r.rejection?.missing.isEmpty == false ? " · missing \(r.rejection!.missing)" : ""))
                    rows.append(["mode": modeName, "draft": name, "outcome": outcome, "tokens": tokens, "seconds": secs,
                                 "missing": r.rejection?.missing ?? [], "improved": r.improved, "changes": r.changes,
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
