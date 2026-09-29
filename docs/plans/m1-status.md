# M1 status — "Zero to first token" (source of truth, updated after every step)

Branch: `m1-first-run` (from `main` @ c5b9bb4) · Started 2026-09-28
Plan reference: `docs/plans/2026-09-28-next-phase-plan.md` §5–6 (M1: #1 hardware-aware first run, #2 in-app download, #4 first chat < 60 s, #5 menu-bar agent).

## Working rules (same as M0)
- Long jobs run in the background with a line-buffered log; read the log, never wait blind.
- Real downloads only for things the user approved; tests use a stubbed `URLSession` (no network).
- Update this file after every step; commit per step.

## Decisions / facts gathered
- **Bonsai licence (decision 8 action item): DONE.** `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` is **Apache-2.0, not gated**; built from Qwen3.8-27B (Apache-2.0). `NOTICE.txt` *requests* attribution ("Created using Bonsai by Prism ML.") when publicly deploying/redistributing. ⇒ no acceptance gate needed; show licence + attribution in onboarding/About; we never re-host (download straight from HF).
- Bonsai repo = 8.61 GB total (`model.safetensors` 8,595 MB LFS + `tokenizer.json` 12.8 MB LFS + small files incl. Python runtime files we will **not** download).
- bge-small = BAAI/bge-small-en-v1.5, MIT, 134 MB.

## Queue
1. [x] **`ModelInstaller`** — DONE (`StackCore/Inference/ModelInstaller.swift`) — resumable, verified, in-app download (no Python, no shell): HF tree API → file list/sizes/sha256; include-list per catalog entry; `.partial` staging + Range resume; SHA-256 verify; atomic rename; disk-space pre-flight; retries; cancellation-safe; progress stream. Tested with a stubbed `URLSession`.
2. [x] **`ModelCatalog`** — DONE (`ModelCatalog.swift`; Bonsai `Models/Bonsai-27B` + bge-small `Models/Embedders/BAAI--bge-small-en-v1.5`, same layout `ModelRegistry`/`LocalEmbedder` already scan) — Bonsai-27B + bge-small entries (repo, install dir matching today's layout, include list, min RAM 16 GiB, licence/attribution).
3. [x] **`HardwareProfile` + `SetupPlan`** — DONE (`StackCore/Inference/SetupPlan.swift`, 8 tests: 18 GB / 16 GB floor / 8 GB / Intel / already-installed / low disk / ETA / current machine) — chip, RAM, free disk → "local + cloud" vs "cloud-only" with plain-language reason (uses `ContextBudget` floor).
4. [x] **Onboarding wiring** — DONE & **verified in the real app** (see step 5) (`SetupModel` 9 tests; new `OnboardingView`/`LocalSetupView`; `AppServices.makeSetupModel`/`finishLocalInstall`; **fixed a regression: onboarding gate now asks for a *chat* provider, since the embedder registering made the registry non-empty**; `HF_ENDPOINT` support, loopback-http only). UI not yet seen running: — first-run screen: detected hardware, one button, progress, licence line; local-model path installs Bonsai + embedder; cloud-only path goes to provider setup.
5. [x] **Run the app and verify** — DONE in the real app (fresh test home, no internet): first-run UI, in-app download, pause at 1.95 GB → resume at the same offset, checksum-verified install, files byte-identical, onboarding exit, model registered and warmed. **Chat with the corrected model (rebuilt app):** "Say hello in five words." → *"Hello there, coding buddy!"* (~11 s from send incl. first-time system-prompt prefill; 4 words, not 5 — model imperfection, not a bug); follow-up "What did I just ask you to do?" → *"You asked me to say hello in five words."* (history carried, cached prefix reused). First-run text wraps correctly after the `fixedSize` fix; hardware line and 8.7 GB/12 min/~14,000-word estimates render.
6. [ ] **Menu-bar agent + login item** — NEXT (`MenuBarExtra`, `SMAppService`).

## Done
- **Installer + catalog** (173 tests total; 16 new, all against a stubbed `URLSession` — *no real network use yet*): includes only model files (never `.py`/`runtime/`), ranged 64 MiB chunks into `.partial/`, resume (re-hashes the partial so it still verifies), SHA-256 from HF's `lfs.oid` for LFS files / size check for small files, corrupt partial discarded, atomic move into place, disk-space pre-flight with a plain-language message, retries with backoff (4×) then a *resumable* error, works when a server ignores `Range`, cancellation keeps the partial, already-installed files skipped, concurrent double-install rejected.
- **Not yet verified against real Hugging Face** (redirects/`Range` through the CDN, real `lfs.oid`s). Plan: ask the user before doing a small real install (bge-small, 134 MB, into a temp dir).

## ✅ FIXED (2026-09-28): local model output was gibberish
**Cause (present since the original implementation — confirmed by probing the pre-wright commit `1604089`):** the Swift Qwen3.5 port was wrong in several places; no earlier benchmark checked output *text*. Fixed against mlx-swift-lm's reference `Qwen35`/`GatedDelta` and the model's real config (`docs/plans/model-facts.md`):
  1. **Gated DeltaNet** linear layers (48 of 64): new `GatedDelta.swift` (reference Metal kernel + reference ops); correct `[q|k|v]` split; β = σ(in_proj_b) and the delta-rule erase/write update; q/k RMS-normalised and scaled; fp32 recurrent state; removed the O(L²) chunked-prefill matrices.
  2. **RoPE:** θ = 1e7 read from `rope_parameters` (was 1e6), only 64 of 256 dims rotated (was all).
  3. **Attention output gate:** per-head `[q_h | gate_h]` split (was `[all q | all gate]`), sigmoid gate.
**Verified on the real model** (`VibeBench --model-check --text-test`): kernel vs reference ops max |Δy| 6e-5, chunked == single call; "The capital of France is" → " Paris" 83.2 %; "…jumps over the lazy" → " dog" 98.6 %; "Say hello in five words." → "Hello, how are you?" — identical at prefill chunk 128/512/8192. Regression tests for the config misreads (θ, partial rotary, shapes, KV bytes/token): 5 new, 196 total.
**Still to do because of this:** re-measure *everything* (tok/s, TTFT, peak GPU, `ContextBudget` constants, 16 GB table) — the old figures were for the wrong computation; note the machine was in **Low Power Mode** during the first correct run; sampling per the model card (non-thinking T 0.7 / top-p 0.8 / top-k 20 / presence 1.5; we're greedy); re-verify the whole flow in the app and time-to-first-token.

## Re-measurement on the corrected model (M3 Pro 18 GB, AC power, Low Power Mode off; chunk 128)
| | old (wrong) model | **corrected model** |
|---|---|---|
| Cold prefill 527 tok | 8.4 s (687 tok), 83 tok/s | **6.58 s, 82.2 tok/s** |
| Cold prefill ~4.2k tok | 51.4 s, 81 tok/s, peak 11.5 GB (86 %) | **49.5 s, 85.5 tok/s, peak 9.89 GB (74 %)** |
| Decode | 10.5–11 tok/s | **10.7–11.3 tok/s** |
| Warm: follow-up turn | 2.0 s | **1.25 s** (30 tokens prefilled) |
| Warm: exact repeat | 0.22 s | **0.23 s** |
| Warm: new session, same system prompt | 0.94 s | **0.91 s** |
| Service test | serial ratio 2.01, cancel → 0.86 s | serial (1.9 s / 3.1 s), **cancel → 0.83 s** |
Prefill speed is compute-bound and unchanged (82–85 tok/s vs ≈104 ceiling for 24.35 B params); peak GPU is ≈1.6 GB lower because the O(L²) matrices are gone. **Memory (peak GPU over weights, chunk 128):** +1.45 / +1.57 / +1.92 / +2.46 GiB at 1,042 / 2,087 / 4,175 / 8,419 tokens (old wrong model: +1.72 / +1.88 / +2.12 / +2.72). `ContextBudget` re-fit to **1.35 GiB fixed + 155 KB/token** (was 1.6 GiB + 165 KB) — resulting limits (74 %-of-RAM working set assumed, embedder reserve included): **8 GB → cloud-only, 16 GB ≈ 8.9k tokens, 18 GB ≈ 17.6k, 24 GB ≈ 43.7k, 32 GB ≈ 78.6k (capped at our 64k)**; essentially unchanged from before because the per-token cost is dominated by KV + snapshot copies. Sweep stopped early on user instruction (chunk 512 and 16k rows are known-slow/worse and were skipped).

## Cloud-provider fixes (from the fact-check) — DONE, 204 tests
`RemoteAPIProvider.endpoint` (no more `/v1/v1`, handles v1beta bases), `max_completion_tokens` for api.openai.com, provider refuses to send an empty model name (clear message), onboarding gets a Model field (default `gpt-4o`) and picks the Anthropic style from the host, model-manager form now actually passes its model field (it used to drop it), stale `claude-3-5-sonnet-20241022` hint replaced. **Still open:** OpenAI `delta.tool_calls` / Anthropic `tool_use` parsing (M2/M3).

## Known gaps carried over
- Local→cloud fallback is silent to the user (M3 adds notice + egress log). No UI control for routing policy yet.
- 16 GB budget assumes working set = 74% of RAM (measured on 18 GB only).
