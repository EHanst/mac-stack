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
Baseline (M3 Pro 18 GB, cold, decode 128): 687 tok → TTFT 8.4 s (83 tok/s prefill, peak GPU 10.9 GB) · 5,588 tok → 69 s (81 tok/s, 12.2 GB) · ~20k tok → *(16k run in flight)*. Prefill is flat ≈ 81–83 tok/s ⇒ TTFT is proportional to uncached tokens; the fix is not re-prefilling.
- [ ] **1. Append-only prompts** — `PromptLedger` stores exactly-sent messages; augmented user message (addendum+framing+RAG) built once. Root causes found: (a) intent addendum/framing/RAG applied only on loop turn 1, so turn 2's system+user text differs → prefix breaks at token ~0; (b) follow-up turns lose earlier RAG/framing; (c) assistant history renders without the `<think>` block the cache saw.
- [ ] **2. Multi-point prefix snapshots** — snapshot at each message boundary; longest-prefix restore; byte-capped store.
- [ ] **3. VibeBench** — warm-prefix case, matmul micro-benchmark at M=512, print `GPU.maxRecommendedWorkingSetBytes()` beside peak GPU.

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
