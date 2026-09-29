# M5 status — "Ship": distribution & hardening (source of truth, updated after every step)

Branch: `m5-ship` (from `m4-agent`) · Started 2026-09-29 · Plan: `docs/plans/2026-09-28-next-phase-plan.md` (Developer ID + notarization, updater, MetricKit, #15 diagnostics, soak tests).
Exit criteria: notarized DMG passes `spctl`; 24 h soak with 3 clients: no leak >5 % RSS, crash-free.

## Blocked on the user (cannot be done from here)
- **No Developer ID identity exists on this Mac** (`security find-identity -v -p codesigning` → 0). Signing, notarizing and `spctl` need an Apple Developer account: a "Developer ID Application" certificate in the keychain and a `notarytool` keychain profile. `scripts/release.sh` already expects `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_KEYCHAIN_PROFILE`.
- **Updater needs a decision** (Sparkle = EdDSA key + an appcast URL to host, or "check GitHub releases and tell the user").

## Queue
1. [x] **M5.1 Diagnostics (#15)** — DONE (`StackCore/Diagnostics/{RequestLog,SupportBundle}.swift`, `DiagnosticsCollector/Model/Card`; 15 tests). Request log, "Why this speed?", support bundle, MetricKit crash reports kept on-device.
2. [x] **M5.2 Soak harness** — DONE: `scripts/soak.py` (isolated home, stub cloud, throwaway token; chat + streaming API + MCP clients; RSS/FD sampling; pass = ≤5 % RSS growth first→last quarter, FDs flat, ≤1 % errors, app alive). 1-min pilot passed (61/61 streams, 0 errors). **24 h run is yours:** `python3 scripts/soak.py --hours 24 --out ~/soak` (needs the Debug app and `.build/debug/vibe-mcp` built; keep the Mac awake).
3. [ ] **M5.3 Vendor libgit2** — Homebrew path in `project.yml` breaks any machine without it (and notarization); bundle it or switch.
4. [ ] **M5.4 Release script dry-run** — check `scripts/release.sh` and `Config/ExportOptions.plist` end to end up to the signing step; hardened runtime + entitlements review.
5. [ ] **M5.5 Launch-hidden-at-login** (open item from M1).
6. [ ] **M5.6 Updater** — after your decision above.

## Done
- **M5.1** `RequestLog` (200 newest, mirrored to `request-log.json`) records every generation through `InferenceService`: source (app/api/background), provider, local/cloud, fallback, prompt/completion tokens (reported, else estimated), time to first token, total, outcome, memory/thermal/Low Power at the start — **no prompt or answer text field exists**. `SlowReason.explain` gives plain-language findings from measurements only: long prompt vs slow first word, another request still running (overlap), memory/thermal/Low Power, cloud/fallback, "slower than your usual" (needs ≥3 earlier requests), or "nothing unusual" with the numbers. `SupportBundle` is a whitelist document (system, load, policy, model ids, timings, egress ledger by kind+host, external server names+status, project *count*, MetricKit reports capped at 5 × 200 KB) with a test that its keys are exactly the whitelist. MetricKit (`MXMetricManager`) payloads are saved under `Application Support/VibeCockpit/Diagnostics` (30 newest); nothing is sent. Settings → "Speed & support": last 10 replies with "Why this speed?", "Export support bundle…" (save panel). Verified in the built app: a chat over the MCP socket produced a `request-log.json` entry (`source: api`, reported 10+5 tokens, no text). **Not verified live:** the card click-through and the save panel; MetricKit delivery (macOS delivers payloads about daily).
- Full suite 358 passing. One `ModelInstaller` test failed once under a full parallel run (`sizeMismatch`, stubbed URLProtocol server) and passed on 3 solo runs and a full rerun — pre-existing flake in code this branch doesn't touch; likely the same family as the earlier unexplained test trap. Not investigated further.
