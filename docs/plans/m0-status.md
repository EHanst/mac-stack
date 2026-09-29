# M0 status (source of truth — updated after every step)

Branch: `m0-foundations` · Last updated: 2026-09-28

## Rules I'm following
- Anything that may run >30 s goes in the background, writes **line-buffered** output to a log, and I read the log — no blind waiting.
- Before launching a benchmark: check nothing else holds the model (`pgrep VibeCockpit`).
- After every step: update this file, then say what changed.

## Done (committed, tests green: 110)
- [x] Plan written: `docs/plans/2026-09-28-next-phase-plan.md`
- [x] `ToolDefinition` carries full JSON Schema (`JSONValue`); MCP→provider bridge; OpenAI-style remote requests now send tool `parameters`
- [x] `Router` (localOnly / localFirst / cloudAllowed) + 8 tests; `preferredProvider` prefers local
- [x] `InferenceScheduler` (priority, FIFO ties, cancel-safe, stream leases) + 6 tests
- [x] `CLAUD.md` HTTP rule relaxed for opt-in loopback API/MCP

## In progress (uncommitted, builds)
- [ ] `GenerationStats` + `LocalMLXProvider.lastStats` (per-request timing/memory)
- [ ] `VibeBench` executable (`Package.swift` target, `Sources/VibeBench/main.swift`)
- [ ] **First benchmark run — not yet completed.** Attempt 1 hung in foreground while `VibeCockpit.app` (pid 5782) was running; app since quit. Attempt 2 ran in background but output was fully buffered (file empty) and was stopped by the user after ~7 s of loading. Fix: line-buffer stdout, log progress, re-run.

## TTFT work (requested 2026-09-28; order 1 → 2 → 3)
Baseline (M3 Pro 18 GB, cold, decode 128): 687 tok → TTFT 8.4 s (83 tok/s prefill, peak GPU 10.9 GB) · 5,588 tok → 69 s (81 tok/s, 12.2 GB) · ~20k tok → **did not finish in 15 min (killed)** — prefill is superlinear or memory-bound at long context; investigate with item 3 (working-set print, matmul ceiling). Prefill is flat ≈ 81–83 tok/s ⇒ TTFT is proportional to uncached tokens; the fix is not re-prefilling.
- [x] **1. Append-only prompts (code + tests done; **verified on the real model**)** — `PromptLedger` stores exactly-sent messages; augmented user message (addendum+framing+RAG) built once. Root causes found: (a) intent addendum/framing/RAG applied only on loop turn 1, so turn 2's system+user text differs → prefix breaks at token ~0; (b) follow-up turns lose earlier RAG/framing; (c) assistant history renders without the `<think>` block the cache saw.
- [x] **2. Multi-point prefix snapshots (code + tests done; **verified on the real model**)** — `PromptSnapshotStore` (system/boundary/tail kinds, longest-prefix restore, 6 entries / 2 GB cap, system entry never evicted), `PrefillPlan` chunking at boundaries, `ChatPromptRenderer` (assistant history now includes the empty `<think>` block so it matches what the cache saw). Segment tokenisation is verified against whole-prompt tokenisation each request; on mismatch it falls back to tail-only.
- [x] **3. VibeBench** — warm-prefix 4-step case, matmul M=512 on real layer shapes, working-set shown as % beside peak GPU, per-generation watchdog. Run complete (results below).

## Results (M3 Pro 18 GB, Bonsai-27B 2-bit, 2026-09-28)
**Warm prefix, ~4.2k-token system prompt** (raw: `bench2.json` in scratchpad)
| step | TTFT | prompt / cached / prefilled | peak GPU |
|---|---|---|---|
| 1 cold | 51.4 s | 4190 / 0 / 4190 | 11.51 GB (86% of working set) |
| 2 follow-up turn (history + new user msg) | **2.0 s** | 4279 / 4189 / 90 | 9.05 GB |
| 3 exact repeat | **0.22 s** | 4279 / 4278 / 1 | 8.64 GB |
| 4 new session, same system prompt | **0.94 s** | 4188 / 4167 / 21 | 8.69 GB |
→ ~25× faster follow-ups; the system-prompt snapshot survives a cleared session.

**Compute ceiling (matmul, M=512, real layer shapes):** bf16 5.4–5.7 TFLOPS; 2-bit 4.8–5.1 TFLOPS → implied prefill ceiling ≈ **94 tok/s** (27B params, ignores attention). Measured cold prefill is 81–83 tok/s = **~87–89% of ceiling**. ⇒ Prefill is compute-bound; kernel tuning can gain ≤ ~13%. Caching (above) and sending fewer tokens are the only large levers.
Decode ≈ 10.5–11 tok/s (unchanged).

## Finding: GPU working-set limit (from item 3's print)
`GPU.maxRecommendedWorkingSetBytes()` = **13.32 GB on this 18 GB M3 Pro** (≈74% of RAM). Peak GPU was 10.9 GB @ 0.7k tokens and 12.2 GB @ 5.6k tokens (91% of the limit) → the ~20k run very likely exceeded it and thrashed (never finished in 15 min). On a 16 GB Mac the limit is probably ≈10–11 GB [G: scaling by the same ratio], only ~2–3 GB above the 8 GB of weights. **The 16 GB floor decision is at risk; needs context caps by RAM tier and lower prefill-intermediate memory. Revisit once the run below finishes.**

## Finding: Metal OOM aborts the whole process (2026-09-28)
Memory-sweep run #1 died on its first row: `libc++abi: terminating due to uncaught exception … [METAL] Command buffer execution failed: Insufficient Memory` (exit 134). Cause here: **Ollama had a 4.8 GB model resident on the GPU** (its other `llama-server` also running), leaving too little of the shared working set. Two consequences for the product, both must be handled in item 1:
1. An OOM is an **uncaught C++ exception → the app crashes**, not a recoverable Swift error. We need a pre-flight guard (refuse/route to cloud *before* dispatch) — can't rely on catching it.
2. Other GPU-resident apps (Ollama, other MLX apps) shrink what we get; a beginner's Mac will often have these. The governor must use *current* free memory, not just RAM tier.
Model load also slowed 4.7 s → 17.9 s under that pressure.

## Results: memory sweep (isolated rows, M3 Pro 18 GB, weights 7.14 GiB, working set 13.32 GiB)
Peak GPU **over weights**, GiB (prefill tok/s):
| chunk | ~1k tok | ~2k | ~4k | ~8.4k |
|---|---|---|---|---|
| 512 (old default) | +3.68 (82.2) | +3.85 (82.0) | +4.04 (82.0) | +4.72 (76.4) |
| 256 | +2.56 (79.6) | +2.68 (80.2) | +2.90 (79.9) | +3.44 (78.6) |
| **128** | **+1.72 (81.2)** | **+1.88 (82.4)** | **+2.12 (82.4)** | **+2.72 (81.2)** |
→ Chunk 128 saves ~2 GiB vs 512 with no speed loss (and no slowdown at 8k). Fit at chunk 128: **fixed ≈ 1.6 GiB + ≈ 0.15 MB/token** (conservative; KV ≈ 64 KB/token + snapshot copy-on-write copies). An earlier sweep was invalid (stale snapshot entries leaked memory between rows — fixed: one `.system` entry only, mislabel fixed, `clearPromptCache()` between rows).

## Result: context budget by RAM tier (model-predicted; working set assumed 74% of RAM, nothing else running)
| RAM | max prompt tokens |
|---|---|
| 8 GB | below floor → cloud-only |
| **16 GB** | **≈ 8.6k** (floor holds, small context) |
| 18 GB | ≈ 16.8k (this Mac measured OK to 8.4k; 16.8k extrapolated, not run) |
| 24 GB | ≈ 41k |
| ≥ 32 GB | 64k (model window) |
On this Mac *right now* the live check gives 8,019 because other apps hold memory. **Caveats [G]:** 74%-of-RAM working-set ratio measured only on the 18 GB machine; the 16 GB row is unmeasured on real 16 GB hardware; snapshot copies cost ~64 KB/token extra and could be trimmed to raise limits later.

## Notes from this step
- Design change to flag: intent guidance (`systemAddendum`) now lives in each user turn (`PromptEngineer.augmentUserTurn`) instead of the system message, because the system message must be fixed for the session. The old `PromptEngineer.engineer(...)` is kept (still tested) but unused by `AppServices`.
- Your WIP (EOS ids `248044/248046`, empty `<think>` in generation prompt) is re-applied and now committed with this change; assistant history renders the same think block for cache consistency.
- One `EmbeddingScheduler` test failed once in a full run (`callCount == 2`) and passed in 3 isolated + 3 full reruns → pre-existing timing flake, not yet root-caused.
- Test count: 129 passing.

## Known not working / gaps
- Local provider **ignores `tools`**: `buildPrompt` never renders tool definitions, so the local model can't call tools (found while reading; not in scope yet).
- Anthropic-style remote provider ignores tools entirely (M2/M3).
- Your original uncommitted edits (EOS ids `248044/248046`, empty `<think>` block in prompt) are saved as a patch at `.../scratchpad/wip.patch` and **not currently applied** to `LocalMLXProvider.swift` — must re-apply after committing the stats change.

## Queue (user-ordered 2026-09-28; do in this order, mark each as it lands)
1. [x] **Long-context memory caps by RAM tier** — DONE. Default prefill chunk 512→**128** (−2 GiB peak, no speed loss). `ContextBudget` (fixed 1.6 GiB + 165 KB/token, 85% of working set, also limited by *currently available* system memory so Ollama etc. count). Provider pre-flight guard refuses oversize prompts with a plain message (verified on the real model: 11.3k-token prompt refused in 0.16 s, no crash); `maxContextTokens()` on `ModelProvider`; `AppServices` trims the ledger to it; local health goes `.unavailable` below the floor.
2. [x] **`StackCore` module split** — DONE: SwiftPM (136 tests pass, `swift build` clean) **and Xcode app target (`xcodebuild` BUILD SUCCEEDED**; `project.yml` lists all three source dirs). Layout: `Sources/StackCore` (Inference, Credentials, Security, Storage, Indexing, Git, Execution, Agent core; **no MCP/SwiftUI/AppKit**; MLX confined here) → `Sources/StackMCP` (MCP server/transport, AgentTool, WebResearchTool, schema bridge) → `Sources/VibeCockpit/App` (= `VibeCockpitCore`: reducer, services, prompt engineering; `@_exported import`s the stack) → `Sources/VibeCockpit/UI` (exe). Notes: `MCP.Message` clashed with our `Message` in AppServices → `ChatMessage` typealias; cross-module imports wrapped in `#if SWIFT_PACKAGE` because the Xcode target is one module.
3. [x] **Wire `InferenceScheduler` + `Router` into `AppServices`** — DONE (145 tests pass). New `StackCore/Inference/InferenceService`: Router picks providers under `RoutingPolicy` (persisted in `UserDefaults["routingPolicy"]`, default localFirst; `AppServices.setRoutingPolicy`), **local providers run through the scheduler, cloud ones don't** (a slow local request never blocks a cloud one — tested with a shared scheduler), fallback to the next provider only if nothing has been produced yet, `RouteNotice` callback reports which provider was used/fell back, `localContextLimit()` feeds the ledger budget. Xcode app target BUILD SUCCEEDED (note: after adding files, re-run `xcodegen generate` — the `.xcodeproj` is gitignored and lists files at generation time). **Verified on the real model** (`VibeBench --service-test`): 2 concurrent requests serialised (second finished at 2.01× the first); cancelling a 600-token generation freed the GPU — next request's first token 0.86 s later. **Known gap → M3:** local→cloud fallback is currently *silent to the user* (only logged + `RouteNotice`); needs the visible notice + egress ledger before cloud fallback ships. No UI control for the policy yet.
4. [x] **Embedder bake-off via `mlx-swift-lm`** — DONE. User approved (2026-09-28): SwiftPM dependency `ml-explore/mlx-swift-lm` 3.31.3 + three HF models (~<1 GB total): `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`, `bge-small-en-v1.5`, `nomic-embed-text-v1.5` (exact repo ids/sizes to be confirmed and logged below). Sub-steps:
   - [x] 4a. Dependency added (`mlx-swift-lm` 3.31.3): resolved with **no other version changes** (mlx-swift 0.31.6, swift-transformers 0.1.24 unchanged); full `swift build` OK. (Tests/Xcode re-check after 4c.) API note: this release's README mentions `MLXEmbeddersHuggingFace`/`MLXLMTokenizers` modules that don't exist yet; use `MLXEmbedders` + `MLXLMCommon` with our own `TokenizerLoader` adapter over swift-transformers.
   - [x] 4b. Eval set: 1,162 `ASTChunker` chunks (56 files, tool sources excluded), 35 hand-written questions, all with verified ground truth (`Sources/VibeEmbedBench/EvalSet.swift`)
   - [x] 4c. `VibeEmbedBench` — results (R@1 / R@5 / R@10 / MRR@10):
     | retriever | R@1 | R@5 | R@10 | MRR | chunks/s | dim | peak GPU |
     |---|---|---|---|---|---|---|---|
     | BM25 (FTS5, fixed) | 34.3 | 88.6 | 91.4 | 0.566 | – | – | – |
     | **bge-small dense** | 60.0 | 88.6 | 91.4 | **0.702** | **117** | 384 | 2.03 GiB |
     | **bge-small + BM25 hybrid** | 60.0 | 88.6 | **94.3** | **0.721** | | | |
     | Qwen3-0.6B-4bit dense | 48.6 | 71.4 | 88.6 | 0.599 | 39 | 1024 | 1.33 GiB |
     | Qwen3-0.6B + BM25 | 51.4 | 85.7 | 88.6 | 0.656 | | | |
     | nomic-v1.5 dense | 28.6 | 74.3 | 85.7 | 0.481 | 66 | 768 | 2.50 GiB |
     | nomic-v1.5 + BM25 | 45.7 | 85.7 | 91.4 | 0.626 | | | |
     **Winner: bge-small-en-v1.5** (best MRR, smallest 134 MB, fastest, 384-dim = existing `VectorStore` default so no schema change). Caveats [G]: 35 queries over one Swift repo — differences of a few points are noise; bge-vs-Qwen3 dense gap (0.70 vs 0.60 MRR) is suggestive, not proof.
     **Bugs found on the way:** (1) FTS5 `sparseSearch` used the whole query as one quoted phrase → **0/35 queries returned anything** (fixed: OR-ed prefix terms via `FTSQuery`; BM25 now R@10 91%). This means offline code search had *never worked* for natural-language questions. (2) Qwen3-Embedding must pool on `<|endoftext|>`, not the tokenizer's EOS `<|im_end|>` (wrong token → R@10 37%; fixed → 88.6%). (3) `mlx-swift-lm` 3.31.3 can't load nomic-embed-text-v1.5 (builds a learned-position table the rotary-only checkpoint lacks); worked around in the bench by patching `max_position_embeddings: 0` in a symlinked copy.
   - [x] 4d. **`LocalEmbedder` (bge-small-en-v1.5) implemented** — `StackCore/Inference/LocalEmbedder.swift`: `.embedding` provider (`local:embed-bge-small-en-v1.5`, `isLocal`), lazy load via `mlx-swift-lm`, batches of 8 / 512 tokens, **runs through the shared `InferenceScheduler`** (indexing `.background`, query `.interactive`) so it can't collide with Bonsai on the GPU; new `ModelProvider.embedQuery` (query instruction prefix; default = plain embed; `IndexingPipeline.search` uses it); registry discovery **skips `Models/Embedders/`** (otherwise the embedder would register as a chat model — tested); `ContextBudget.reservedBytes` (300 MiB) reserved from the chat model's budget; `AppServices` registers it at startup if installed and shares one `gpuScheduler`. Tests: 157 pass (batching, discovery, not-installed behaviour). **Real-model verification** (`VibeEmbedBench --self-test`, since MLX can't find its metallib inside `swift test`): 10/10 provider checks (384-dim, unit norm, related>unrelated, query prefix applied, deterministic, order preserved, queues behind a held GPU slot) **and end-to-end offline search — 60 files indexed in 17.1 s through `IndexingPipeline` with only the local embedder registered: R@1 57.1 / R@5 88.6 / R@10 97.1 / MRR 0.702**.
   - **Not done (M1):** in-app download of the embedder (today it must already be in `Models/Embedders/`); `ModelDownloadManager` handles single files only. Pipeline embeds raw chunk text — the bake-off prefixed `File: X (kind)`; try that as a cheap quality tweak. Xcode target needed `mlx-swift-lm` added to `project.yml` (done) — **`xcodebuild` BUILD SUCCEEDED**.
   - Downloads log (approved, started 2026-09-28; dest `~/Library/Application Support/VibeCockpit/Models/Embedders/`, size-verified by `curl` script, licences apache-2.0 / mit, none gated): Qwen3-Embedding-0.6B-4bit-DWQ 351 MB · bge-small-en-v1.5 134 MB · nomic-embed-text-v1.5 548 MB → **1.03 GB total (slightly over the ~1 GB quoted)**. Status: **complete, all files size-verified** (on disk: Qwen3 ~351 MB, bge-small ~134 MB, nomic ~548 MB).

## Remaining M0
- [x] Benchmark numbers on M3 Pro 18 GB (512 / 4k done; 16k+ hangs — see working-set finding)
- [ ] Long-context memory: cap prefill intermediates / context by RAM tier (new, from working-set finding)
- [x] Re-apply WIP patch (committed with items 1–2)
- [ ] Split `StackCore` from adapters (module boundary) — not started
- [ ] Embedder bake-off via `mlx-swift-lm` — not started; needs model downloads (will ask first)
- [ ] Wire scheduler/router into `AppServices` — not started
