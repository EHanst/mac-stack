# M2 status — "Serve": other apps can use the stack (source of truth, updated after every step)

Branch: `m2-serve` (stacked on `m1-menubar` / PR #3) · Started 2026-09-29
Plan: `docs/plans/2026-09-28-next-phase-plan.md` §5–6 (M2: #6 scheduler ✅, #7 OpenAI-compatible API, #8 MCP v2, #9 per-client tokens/scopes, #10 tool permission prompts, #12 Connect-an-app).
Decisions in force: API is **opt-in, 127.0.0.1 only, per-client bearer tokens, off by default**; Unix socket stays the zero-config MCP default; HTTP framework = **Hummingbird 2**; one process holds the weights.

## Working rules
- Long jobs in the background with line-buffered logs; skip known-slow/known-worse configurations (see memory); check `pmset -g batt` before GPU work.
- Real downloads only for things approved; SwiftPM dependency = Hummingbird (decision 6, approved).
- **Every model-facing feature is verified on the real model with text checked, not just timings** (lesson from the gibberish bug).
- Update this file after every step; commit per step; don't change system settings.

## Queue
1. [x] **M2.1 `ClientRegistry`** — DONE (`StackCore/Security/ClientRegistry.swift`, 11 tests) — clients, scoped bearer tokens (`vc_…`, shown once, stored hashed), revoke, persistence 0600, last-used. Tests.
2. [x] **M2.2 OpenAI-compatible translation** — DONE (`StackHTTP/OpenAI/*`, `OpenAICompatTests`): request JSON → `[Message]`/options; `GenerationEvent` → SSE chunks / full response; errors in OpenAI shape; usage.
3. [x] **M2.3 `StackHTTP` server** — DONE (`StackHTTP/Server/*`, `StackAPIServerTests`, 18 tests over a live loopback socket with stub providers): loopback bind, Bearer auth + scopes, Host/Origin checks (DNS-rebinding), `/v1/models`, `/v1/chat/completions` (stream + non-stream, keep-alives), `/v1/embeddings`, `/healthz`, OpenAI-shaped 404/4xx/5xx.
4. [x] **M2.4 `InferenceService`** — DONE (in `InferenceServiceTests`): pin a provider by `model` id (no fallback; cloud refused under "Only on this Mac"), `.api` priority, token usage, embedding routing.
5. [ ] **M2.5 Real-model verification** — HARNESS READY, NOT RUN (Mac on battery; Ollama holds two models in GPU memory → OOM risk). Run when plugged in and Ollama unloaded: `swift run -c release VibeBench --contexts none --warm-prefix 0 --no-matmul --api-test`. Checks: streaming completion via HTTP with sensible text; concurrent UI + API requests; cancel on client disconnect frees the GPU.
6. [ ] **M2.6 App wiring + UI**: server lifecycle in `AppServices`, Settings "Share with other apps" (off by default), clients list with create/revoke, token shown once.
7. [ ] **M2.7 MCP v2**: multi-client Unix socket, Streamable HTTP (SDK transport + bearer/origin validators), `chat`/`embed`/`list_models` tools, workspace-less mode, `vibe-mcp` stdio shim replacing `socat`.
8. [ ] **M2.8 Tool permission prompts + scopes** (read free; write/exec ask; remember per client).
9. [ ] **M2.9 "Connect an app"** screen with copy-paste snippets (Claude Desktop, Cursor, OpenAI SDK) + test button.

## Facts / constraints that shape the work
- Local model **ignores `tools`** (prompt doesn't render them) → the API rejects `tools` with a clear 400 for local models until tool calling is implemented (M4); cloud providers still get them.
- Sampling for API requests: `temperature`/`top_p`/`top_k`/`presence_penalty` map to `SamplingParameters`; absent ⇒ model-card defaults.
- `max_tokens`/`max_completion_tokens` map to `GenerationOptions.maxTokens` (default 8192).
- MCP swift-sdk 0.12.1 already provides `StatefulHTTPServerTransport` + `OriginValidator`/`BearerTokenValidator` — reuse for Streamable HTTP.

## Done
- **M2.1** tokens `vc_` + 43 base64url chars (256 random bits), shown once; only the SHA-256 is stored; revoke is immediate and persisted; per-client scopes (new clients: models/chat/embeddings only — no file access); "last used" kept in memory and flushed ≤ once/minute; file store is atomic, 0600, no plaintext token anywhere (tested).
- **M2.2–M2.4** Full suite 276 passing. Server verified against stub providers only: streaming shape (role → deltas → finish → optional usage → `[DONE]`), keep-alive comments during a slow first token, 401/403/421 (bad `Host`)/403 (`Origin`), tools refused for local/unpinned models but allowed for a named cloud model, pinned model used exactly (unknown → 404, blocked by privacy switch → 403), embeddings, and **client disconnect terminates the provider stream**. Not yet verified on the real model (M2.5). Test client hits `localhost`, which the live test server binds as `::1`; the app binds `127.0.0.1`.
