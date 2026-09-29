# M3 status — "Cloud & routing": cloud as a controlled fallback (source of truth, updated after every step)

Branch: `m3-cloud` · Started 2026-09-29 · Plan: `docs/plans/2026-09-28-next-phase-plan.md` §5–6 (#11 cloud presets + Keychain UI, #13 router/budget/egress ledger, #14 governor).
Exit criteria: forced local failure falls back per policy; **Only on this Mac makes zero outbound requests** (verified by ledger + socket check); budget cap blocks at the limit.

## Working rules
- Fact-check any provider/model/price claim before it ships in code or UI (standing instruction). **No prices are hard-coded**: the monthly limit is in *tokens*, not dollars.
- Update this file after every step; commit per step; merge/push only when asked.

## Queue
1. [x] **M3.1 EgressGate** — DONE. One gate every outbound request passes (`StackCore/Privacy/EgressGate.swift`): enforces Only-on-this-Mac, enforces the monthly token limit, records host + purpose (never content). Wired into `RemoteAPIProvider`, `ModelInstaller`, `WebFetchTool`, `WebSearchTool`, `InferenceService` (limit check + token accounting).
2. [x] **M3.2 App wiring + Settings** — DONE (`AppServices.egress`, `CloudUsageModel`, `CloudUsageCard`; 2 tests): gate in the app (policy kept in sync), monthly limit picker, usage bar, "What left this Mac" ledger with Clear.
3. [x] **M3.3 Fallback you can see + governor** — DONE (`SystemGovernor`, `InferenceService.generate(onRoute:)`, HTTP `model` field + `X-VibeCockpit-Served-By`/`-Fallback-From` headers, chat notice line, menu line; 12 tests). Original scope: local→cloud fallback notice in chat / API response header, ledger line; governor (`DispatchSource` memory pressure, `thermalState`, Low Power Mode → smaller context / route to cloud).
4. [ ] **M3.4 Cloud presets + Keychain UI** (OpenAI, Anthropic, OpenRouter, Ollama): pick provider → paste key → model name; no JSON editing. **Model names/base URLs verified against each provider's docs before shipping.**
5. [ ] **M3.5 Verification in the real app**: policy switch → zero connections to a loopback "cloud"; fallback with the real local model stopped; limit blocks.

## Done
- **M3.1** Real-socket tests (a Hummingbird server standing in for the cloud): Only on this Mac → **0 connections** even when the model is named and while health checks run; Local first with no local model → request goes out, is ledgered, counts tokens; limit reached → next request never leaves; switching policy applies immediately. Ledger merges repeats, capped at 500, no URLs' query strings/prompt text stored. 319 tests pass.
- **Bug found and fixed on the way:** cloud *health checks were real paid completions* ("hi", 1 token) sent on every status refresh. They now `GET /models` (free); servers without that endpoint (404/405) count as reachable.
- Not gated yet: the legacy `ModelDownloadManager` (unused by the app; only referenced by an eval set) — delete or gate in a later cleanup.
- **M3.2** Real app (built), stub "cloud" on loopback, same fake home, only the privacy setting changed: **Local first** → app's health probe `GET /v1/models` reached the stub twice, ledgered as `cloudInference 127.0.0.1 ×2`; **Only on this Mac** → **stub saw no request at all**, no established connection, ledger shows `blocked — Only on this Mac ×2`. The new Settings card renders in the build but I couldn't click through it (window on another Space).
- **M3.3** (a) Fallback is visible three ways: a grey line in chat ("The model on this Mac couldn't answer (…), so this reply comes from openai in the cloud."), the API's `model` field and `X-VibeCockpit-Served-By` / `X-VibeCockpit-Fallback-From` headers name the model that really answered, and the egress log already shows the request. (b) Governor watches memory pressure, thermal state and Low Power Mode: under **Cloud allowed** a strained Mac routes to the cloud (with a chat line saying why); under **Local first** the user's choice wins and nothing changes; **critical** memory pressure drops the local model's saved prompt snapshots; the menu shows the reason. Tested with injected load and stub providers, plus the app build compiles. **Not exercised for real:** the OS memory/thermal/Low Power signals (can't be induced without changing system settings) and the chat line in the running app.
