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
- [x] **1. Append-only prompts (code + tests done; not yet measured end-to-end)** — `PromptLedger` stores exactly-sent messages; augmented user message (addendum+framing+RAG) built once. Root causes found: (a) intent addendum/framing/RAG applied only on loop turn 1, so turn 2's system+user text differs → prefix breaks at token ~0; (b) follow-up turns lose earlier RAG/framing; (c) assistant history renders without the `<think>` block the cache saw.
- [x] **2. Multi-point prefix snapshots (code + tests done; not yet measured on the real model)** — `PromptSnapshotStore` (system/boundary/tail kinds, longest-prefix restore, 6 entries / 2 GB cap, system entry never evicted), `PrefillPlan` chunking at boundaries, `ChatPromptRenderer` (assistant history now includes the empty `<think>` block so it matches what the cache saw). Segment tokenisation is verified against whole-prompt tokenisation each request; on mismatch it falls back to tail-only.
- [ ] **3. VibeBench** — warm-prefix case, matmul micro-benchmark at M=512, print `GPU.maxRecommendedWorkingSetBytes()` beside peak GPU.

## Notes from this step
- Design change to flag: intent guidance (`systemAddendum`) now lives in each user turn (`PromptEngineer.augmentUserTurn`) instead of the system message, because the system message must be fixed for the session. The old `PromptEngineer.engineer(...)` is kept (still tested) but unused by `AppServices`.
- Your WIP (EOS ids `248044/248046`, empty `<think>` in generation prompt) is re-applied and now committed with this change; assistant history renders the same think block for cache consistency.
- One `EmbeddingScheduler` test failed once in a full run (`callCount == 2`) and passed in 3 isolated + 3 full reruns → pre-existing timing flake, not yet root-caused.
- Test count: 129 passing.

## Known not working / gaps
- Local provider **ignores `tools`**: `buildPrompt` never renders tool definitions, so the local model can't call tools (found while reading; not in scope yet).
- Anthropic-style remote provider ignores tools entirely (M2/M3).
- Your original uncommitted edits (EOS ids `248044/248046`, empty `<think>` block in prompt) are saved as a patch at `.../scratchpad/wip.patch` and **not currently applied** to `LocalMLXProvider.swift` — must re-apply after committing the stats change.

## Remaining M0
- [ ] Benchmark numbers on M3 Pro 18 GB (512 / 4k / 16k ctx)
- [ ] Re-apply WIP patch
- [ ] Split `StackCore` from adapters (module boundary) — not started
- [ ] Embedder bake-off via `mlx-swift-lm` — not started; needs model downloads (will ask first)
- [ ] Wire scheduler/router into `AppServices` — not started
