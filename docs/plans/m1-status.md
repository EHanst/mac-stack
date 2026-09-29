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
4. [ ] **Onboarding wiring** — first-run screen: detected hardware, one button, progress, licence line; local-model path installs Bonsai + embedder; cloud-only path goes to provider setup.
5. [ ] **Run the app and verify** (screenshot) the first-run flow.
6. [ ] **Menu-bar agent + login item** (`MenuBarExtra`, `SMAppService`).

## Done
- **Installer + catalog** (173 tests total; 16 new, all against a stubbed `URLSession` — *no real network use yet*): includes only model files (never `.py`/`runtime/`), ranged 64 MiB chunks into `.partial/`, resume (re-hashes the partial so it still verifies), SHA-256 from HF's `lfs.oid` for LFS files / size check for small files, corrupt partial discarded, atomic move into place, disk-space pre-flight with a plain-language message, retries with backoff (4×) then a *resumable* error, works when a server ignores `Range`, cancellation keeps the partial, already-installed files skipped, concurrent double-install rejected.
- **Not yet verified against real Hugging Face** (redirects/`Range` through the CDN, real `lfs.oid`s). Plan: ask the user before doing a small real install (bge-small, 134 MB, into a temp dir).

## Known gaps carried over
- Local→cloud fallback is silent to the user (M3 adds notice + egress log). No UI control for routing policy yet.
- 16 GB budget assumes working set = 74% of RAM (measured on 18 GB only).
