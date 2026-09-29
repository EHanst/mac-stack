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
4. [~] **Onboarding wiring** — code + tests DONE (`SetupModel` 9 tests; new `OnboardingView`/`LocalSetupView`; `AppServices.makeSetupModel`/`finishLocalInstall`; **fixed a regression: onboarding gate now asks for a *chat* provider, since the embedder registering made the registry non-empty**; `HF_ENDPOINT` support, loopback-http only). UI not yet seen running: — first-run screen: detected hardware, one button, progress, licence line; local-model path installs Bonsai + embedder; cloud-only path goes to provider setup.
5. [~] **Run the app and verify** the first-run flow — plan: fresh `CFFIXED_USER_HOME`, dev-only local HF mirror (`scratchpad/hf_mirror.py`, serves the model files already on disk over 127.0.0.1 with Range + sha256, so **no internet download**), drive with computer-use, then a real chat for first token.
6. [ ] **Menu-bar agent + login item** (`MenuBarExtra`, `SMAppService`).

## Done
- **Installer + catalog** (173 tests total; 16 new, all against a stubbed `URLSession` — *no real network use yet*): includes only model files (never `.py`/`runtime/`), ranged 64 MiB chunks into `.partial/`, resume (re-hashes the partial so it still verifies), SHA-256 from HF's `lfs.oid` for LFS files / size check for small files, corrupt partial discarded, atomic move into place, disk-space pre-flight with a plain-language message, retries with backoff (4×) then a *resumable* error, works when a server ignores `Range`, cancellation keeps the partial, already-installed files skipped, concurrent double-install rejected.
- **Not yet verified against real Hugging Face** (redirects/`Range` through the CDN, real `lfs.oid`s). Plan: ask the user before doing a small real install (bge-small, 134 MB, into a temp dir).

## 🚨 OPEN ISSUE (found 2026-09-28 during step 5): local model output is gibberish — root cause found
Real app (fresh install, files byte-identical) and `VibeBench --text-test` both emit multilingual nonsense; **identical output at prefill chunk 128/512/8192** ⇒ chunking/snapshots/prompt are *not* the cause. Nothing measured before today checked output *text* (only speed/memory), so every benchmark so far measured a model that was producing garbage.
**Root cause (from reading `Sources/StackCore/Inference/Qwen35Model.swift` `BonsaiLinearAttn` against mlx-swift-lm's reference `MLXLLM/Models/Qwen35.swift` + `GatedDelta.swift`):** the linear-attention layers are implemented as a "Mamba2-style" approximation, not Qwen3.5's **Gated DeltaNet**:
  1. **Wrong q/k/v split** of `in_proj_qkv`: real layout is `[q: keyDim 2048 | k: keyDim 2048 | v: valueDim 6144]`; ours slices `[6144 | 2048 | 2048]`.
  2. **No delta rule**: missing `beta = sigmoid(in_proj_b)` (code even says "unused in fwd for now") and the erase term — real update is `S = g·S; Δ = (v − S·k)·β; S += k⊗Δ; y = S·q`; ours is `S = g·S + k⊗v`.
  3. **No q/k normalisation**: real = `q ← (1/Dk)·rmsNorm(q)`, `k ← (1/√Dk)·rmsNorm(k)` (weightless, eps 1e-6).
  (The decay `g = exp(−exp(A_log)·softplus(a+dt_bias))` *is* right.) Also possible: other layers (RMSNorm `1+weight`?, partial-rotary, gate) — to be checked against the reference.
**Fix plan:** port Gated DeltaNet (reference Metal kernel `gated_delta_step`, MIT via mlx-lm) into `BonsaiLinearAttn`, keeping our Prism-packed linears; then verify with `--text-test` and a "capital of France" top-token check. Side effects to expect: removes the O(L²) chunked-prefill matrices (⇒ the "fixed 1.6 GiB + per-token" memory model and **`ContextBudget` constants must be re-measured**); state layout becomes `[B, Hv, Dv, Dk]`; prefill/decode speeds will change (all earlier tok/s figures were for the wrong computation).
**Confirmed:** a probe built at the pre-wright commit `1604089` (before all M0/M1 work) emits the same kind of gibberish — this bug is in the original model implementation, not a regression. Full fact-check of the model/config/cloud assumptions: `docs/plans/model-facts.md` (adds: rope θ 1e7 & 25 % partial rotary, per-head attention-gate layout, sigmoid-vs-swish gate, fp32 GDN state, recommended non-thinking sampling T 0.7/top-p 0.8/top-k 20/presence 1.5). **Every speed/memory number in `m0-status.md` and this file was measured on the wrong computation and must be re-measured after the fix.**

## Known gaps carried over
- Local→cloud fallback is silent to the user (M3 adds notice + egress log). No UI control for routing policy yet.
- 16 GB budget assumes working set = 74% of RAM (measured on 18 GB only).
