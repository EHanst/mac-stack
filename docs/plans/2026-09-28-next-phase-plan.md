# VibeCockpit — Next Phase Plan: "Local AI Stack Host"

**Date:** 2026-09-28 · **Status:** Decisions resolved 2026-09-28 · **Basis:** audit of `main` @ `78f675c` (96 tests passing), host M3 Pro / 18 GB / macOS 26.6

Legend: **[F]** fact verified in the repo · **[R]** recommendation · **[G]** guess (needs measurement).

---

## 1. Assumptions and open questions (ranked by impact)

| # | Assumption / question | If wrong… |
|---|---|---|
| 1 | **Product identity shifts** from "vibe-coding IDE" (diff canvas, snapshots, build loop) to a *stack host* with a thin UI; IDE features become one client/pack. | Roadmap M1–M3 reorders around IDE polish instead. |
| 2 | **`CLAUD.md` forbids HTTP/localhost servers [F]**; the new vision requires an API. Assumed the rule is superseded for an opt-in, loopback-only, token-authed server. | Without an HTTP path, "any other app via API" is impossible; MCP-over-socket only. |
| 3 | Core model = **Ternary-Bonsai-2-27B, 2-bit MLX, ~8 GB on disk [F]**, run by our own Swift Qwen3.5 implementation (`Qwen35Model.swift`, `PrismHadamard.swift`). **Decided: Bonsai is the only local *chat* model**; `mlx-swift-lm` is added for auxiliary models (embedder now, others later). | A second local chat model would reopen the memory and maintenance trade-offs. |
| 4 | **Hardware floor: 16 GB unified memory** for local inference [G — 27B weights ≈ 8 GB; M0 must confirm context limits at 16 GB]. Macs below 16 GB run **cloud-only mode** rather than being refused. | If 16 GB can't sustain useful context, raise the floor to 24 GB or cap context on 16 GB. |
| 5 | **Distribution:** Developer ID + notarized DMG, *not* Mac App Store [F: sandbox is off, `allow-unsigned-executable-memory` on]. | MAS forces a sandbox rewrite (file access, sockets, XPC runner). |
| 6 | Team of 2 engineers; durations in §5 scale linearly with that. | — |
| 7 | Bonsai weights license permits redistribution/download from our UI [unverified]. | Download flow must send users to the source and record license acceptance. |
| 8 | Minimum OS stays **macOS 26** [F: `Package.swift`]. Narrow audience, but frees us from back-deploy work. | — |

## 2. Product thesis, principles, non-goals

**Thesis:** *One Mac app that turns an Apple-silicon Mac into a private AI endpoint.* Install, click once, get a working model; every other tool (chat, editors, agents) plugs into it over MCP or an OpenAI-compatible API; the cloud is a fallback the user controls.

**Principles (each resolves a simplicity-vs-power tension):**
1. **One model copy, one process.** The app owns the weights; UI, API, MCP and CLI are clients of it. Never load 8 GB twice.
2. **Zero-config default, progressive disclosure.** First run shows one button and one status light. Ports, tokens, routing rules appear only after "Share with other apps" is turned on.
3. **Local first, cloud by explicit policy.** Three-position switch (Local only / Local first / Cloud allowed). Any byte that leaves the Mac is logged and visible.
4. **Safe by default for clients.** Read-only tools free; write/exec tools ask; every client has its own revocable token.
5. **Core has no UI and no protocol types.** MCP, HTTP and SwiftUI are adapters over one `StackCore`.
6. **Measure before optimizing.** A benchmark harness gates every perf claim.
7. **Fail with a sentence, not a stack trace.** Every error maps to a plain-language cause and one action.

**Non-goals (deliberately cut):** fine-tuning/training, multi-user or network-exposed serving, Windows/Linux, multimodal, a plugin marketplace, a general agent framework, a built-in eval suite, Docker/VMs, Python anywhere in the user path.

## 3. What the audit found (grounding)

| Area | State on `main` | Consequence |
|---|---|---|
| Inference exposure | MCP tools = `search_code`, `index_workspace`, `read_file`, `write_file`, `run_build`, `snapshot_create`, `snapshot_diff` **[F]**. No `chat`/`embed` tool; no HTTP API. | Other apps cannot use the model at all today. |
| **Embeddings** | `LocalMLXProvider` capabilities are `[.textGeneration, .streaming]`; `embed()` throws `unsupported` **[F]**. `IndexingPipeline` needs a provider with `.embedding`. | **A local-only user gets no code search/RAG.** Largest hidden gap vs. the "local stack" promise. |
| MCP transport | Unix socket `~/.vibecockpit/mcp.sock`; single `clientFD` (one client at a time); users need `socat` **[F]**; no socket chmod or auth. Tools only (no resources/prompts); no MCP *client*. Server starts **only if a workspace is detected** **[F]**. | Not entry-level; not multi-client; no workspace → no server. |
| Stdio sidecar | `VibeCockpitMCPServer` (stdio) was built on a branch, then superseded by the embedded design **[F]**. | We need a *thin proxy*, not a second server (§4). |
| Provider layer | `ModelProvider` actor protocol, `RemoteAPIProvider` (OpenAI / Anthropic / Ollama styles), Keychain-or-env credentials **[F]**. `preferredProvider` just sorts by id **[F]** (no policy). Remote configs are hand-edited `~/.config/vibecockpit/providers.json`. `ToolDefinition.inputSchema` is `[String:String]`. | Good seam; no router, no UI setup, tool schemas can't express JSON Schema. |
| Model management | Registry only accepts Qwen-family bundles (rejects llama/mistral/gemma/phi) **[F]**; `download_bonsai.sh` requires python3 + venv **[F]**; download manager takes user-supplied manifests. | Not usable by a beginner; single-architecture. |
| Runtime | `ModelRuntime` actor (load dedupe, idle eviction), pipelined decode + prompt-prefix snapshot cache (just merged from `beautiful-wright`), 64k default context **[F]**. | Solid base; needs a scheduler for multiple clients. |
| Security | App sandbox off; XPC `BuildRunner` isolates execution; `WorkspaceBoundary` validates paths **[F]**. | Fine for a dev tool; needs client auth + tool prompts once external clients arrive. |

## 4. Target architecture

```
                 ┌────────────── VibeStack.app  (single process, menu-bar agent + optional window) ─────────────┐
 Clients         │                                                                                              │
 ───────         │  Adapters (protocol only, no logic)                                                          │
 SwiftUI window ─┼─► UI (@Observable, in-process)                                                               │
 Claude Desktop ─┼─► MCP server  ─ Unix socket (0600, multi-client)  ◄── `vibe-mcp` stdio shim (tiny CLI)       │
 Cursor / Zed   ─┼─►             └ Streamable HTTP (127.0.0.1, bearer)                                          │
 any OpenAI SDK ─┼─► HTTP API   /v1/chat/completions · /v1/embeddings · /v1/models  (SSE streaming)             │
                 │        │                                                                                     │
                 │        ▼                                                                                     │
                 │  StackCore  (actors, AsyncThrowingStream, cancellation via Task)                             │
                 │   ├ ClientRegistry   identity · tokens · scopes · rate limits                                │
                 │   ├ ToolRegistry     one list, exposed to MCP *and* to the model; permission gate            │
                 │   ├ Router           policy: local-only | local-first | cloud-allowed · budget · egress log  │
                 │   ├ Scheduler        priority queue (UI > API > indexing), prefix-cache reuse, cancel        │
                 │   ├ ModelRuntime     load / warm / evict · memory-pressure + thermal governor                │
                 │   └ Stores           VectorStore (sqlite-vec+FTS5) · workspaces · usage ledger               │
                 │        │                                                                                     │
                 │        ▼  ModelProvider (existing protocol, extended)                                        │
                 │   LocalMLXProvider (Bonsai, custom MLX) · LocalEmbedder (mlx-swift-lm) · RemoteAPIProvider   │
                 │   MCPClient (uses user-configured external MCP servers as model tools)                       │
                 │                                                                                              │
                 │  XPC BuildRunner (sandboxed exec)  ← only reachable through ToolRegistry                     │
                 └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Package boundaries** [R]: `StackCore` (library, no MCP/HTTP/SwiftUI imports) → `StackMCP`, `StackHTTP` (adapters) → `VibeStackApp` (UI + lifecycle) and `vibe-mcp` (≤200-line executable that only forwards stdio ↔ the app's socket, replacing `socat`). Keep the existing `VibeCockpitCore` as the seed of `StackCore`; split incrementally, not big-bang.

**Process model** [R]: **one app process** registered as a login item (`SMAppService`) and menu-bar extra (`MenuBarExtra`); window is optional. No separate daemon: a daemon would either duplicate the 8 GB model or force IPC for every token. The only helper stays the sandboxed XPC build runner. Trade-off accepted: if the app quits, the endpoint disappears — mitigated by login-item auto-start. Change our mind if users demand headless/SSH use.

**Concurrency model:** `Scheduler` is an actor that owns the single GPU stream; requests are value-typed jobs producing `AsyncThrowingStream<GenerationEvent, Error>`; client disconnect or `Task.cancel()` propagates to the decode loop (already checks `Task.isCancelled`). Start with **serial execution + priorities**; continuous batching is P2 because it means rewriting the decode path around a batched KV cache.

**Provider abstraction changes** [R]: (a) structured tool calls and JSON-Schema `inputSchema` (`Value`, not `[String:String]`); (b) `ProviderCapabilities` gains `.local`/`.cloud` and cost metadata; (c) `Router` replaces `preferredProvider`; (d) `LocalEmbedder` provider (via `mlx-swift-lm`) satisfies `.embedding` offline; retrieval must degrade to BM25-only, not silently return nothing, if it is absent.

**MCP transports:** keep Unix socket (zero-config, no port); add multi-client accept loop; add Streamable HTTP on loopback for clients that can't do sockets; ship `vibe-mcp` for stdio-only hosts. **Hard-to-reverse decisions:** HTTP-on-loopback policy, one-process model, token/scope schema. **Cheap to change later:** which embedding model, router defaults, UI layout.

## 5. Suggestions (prioritized)

| # | Idea | User value | Effort | Pri |
|---|---|---|---|---|
| 1 | **Hardware-aware first run**: detect chip/RAM (`sysctl`, `ProcessInfo`); ≥16 GB Macs get one "Set up" button; <16 GB Macs are offered cloud-only mode with the same UI | Beginner never chooses a model | M | P0 |
| 2 | **In-app resumable model download** (URLSession background, SHA-256, license accept); delete `download_bonsai.sh` | No Python/terminal | M | P0 |
| 3 | **Always-on local embedder via `mlx-swift-lm`** (small embedding model, ~100–300 MB [G]; model choice from M0 bake-off on a code-search test set) implementing `.embedding`. BM25-only (`VectorStore` FTS5) remains the fallback if the embedder is absent | Code search works offline; fixes the biggest gap | M | P0 |
| 4 | **First chat < 60 s** with starter prompts; model pre-warmed while downloading finishes | Instant proof it works | S | P0 |
| 5 | **Menu-bar agent + login item**; popover: health light, tok/s, connected clients, quit | "It's just running" simplicity | M | P0 |
| 6 | **Request scheduler**: priorities, cancellation, prompt-prefix cache shared across requests | Multiple apps without stalls | M | P0 |
| 7 | **OpenAI-compatible API** (`/v1/chat/completions` with SSE + tools, `/v1/embeddings`, `/v1/models`), opt-in, 127.0.0.1 | Every existing SDK/app works | L | P0 |
| 8 | **MCP server v2**: multi-client, Streamable HTTP, `vibe-mcp` shim, inference tools (`chat`, `embed`), resources (indexed workspaces), works with **no workspace** | Other apps use the stack; no `socat` | L | P0 |
| 9 | **Per-client tokens & scopes** in Keychain, revocable; socket chmod 0600 | Safe multi-app access | M | P0 |
| 10 | **Tool permission prompts** (read free; write/exec ask; remember per client) | Trust without friction | M | P0 |
| 11 | **Cloud presets + Keychain UI** (OpenAI, Anthropic, OpenRouter, Ollama); no JSON editing | Cloud fallback in 30 s | M | P0 |
| 12 | **"Connect an app" screen**: copy-paste/one-click config for Claude Desktop, Cursor, VS Code, Zed + test button | Time-to-first-integration | S | P1 |
| 13 | **Router**: Local-only / Local-first / Cloud-allowed switch; fallback on unavailable, over-context, RAM pressure; monthly budget; **egress ledger** | Control over privacy and cost | L | P1 |
| 14 | **Governor**: `DispatchSource` memory-pressure, `thermalState`, Low Power Mode → shrink context / unload / route to cloud | Doesn't freeze the Mac | M | P1 |
| 15 | **"Why is it slow?" diagnostics** + request log + one-click support bundle (no prompt text by default) | Beginner-friendly debugging | M | P1 |
| 16 | **Workspace-less + multi-workspace mode** | Server useful without a project | M | P1 |
| 17 | **MCP client**: model can call user-approved external MCP servers | Ecosystem leverage | L | P1 |
| 18 | **Prompt-injection guardrails**: tag untrusted content (web, MCP results, cloud text); require confirmation for write/exec when untrusted content is in context; no silent fetch→write chains | Safety as the surface widens | M | P1 |
| 19 | **KV-cache quantization + speculative decoding** with a small draft model (`.speculativeDraft` capability already exists) | Faster tokens/s | L | P2 |
| 20 | **Continuous batching** & Swift-package tool extension points (compile-time, no dynamic loading) | Scale and extensibility | L | P2 |

## 6. Phased roadmap (2 engineers; durations are estimates [G])

| M | Goal | Scope / deliverables | Depends on | Exit criteria (measurable) | Time |
|---|---|---|---|---|---|
| **M0 Foundations** | Make the seams real | ADR on HTTP loopback; split `StackCore` from adapters; Scheduler + Router skeleton; benchmark harness (`tok/s`, TTFT, RSS); JSON-Schema tool types | — | Harness runs in CI-lite on M-series; all 96 tests green; core builds without UI/MCP imports | 2 wk |
| **M1 Zero to first token** | Beginner path | #1 #2 #3 #4 #5 | M0 | Clean Mac at/above the measured floor → first token ≤ target (§7) without terminal; no Python invoked; code search works with network off; below-floor Mac reaches a working cloud chat | 3 wk |
| **M2 Serve** | Other apps can use us | #6 #7 #8 #9 #10 #12 | M0, M1 scheduler | OpenAI Python/JS SDK + Claude Desktop + Cursor each complete a chat and a tool call; 3 concurrent clients don't error; revoked token is refused | 4 wk |
| **M3 Cloud & routing** | Cloud as controlled fallback | #11 #13 #14 | M2 | Forced local failure falls back per policy; Local-only mode makes **zero** outbound requests (verified by ledger + packet check); budget cap blocks at limit | 3 wk |
| **M4 Agent surface** | Safe tool ecosystem | #16 #17 #18 | M2 tool registry | Injection test corpus: 0 unconfirmed write/exec after untrusted content; MCP client tools appear in `tools/list` and model calls | 3 wk |
| **M5 Ship** | Distribution & hardening | Developer ID + notarization, updater, MetricKit crash reporting, #15, soak tests | M3 | Notarized DMG passes `spctl`; 24 h soak with 3 clients: no leak >5% RSS, crash-free | 2 wk |
| **P2 backlog** | Perf & extensibility | #19 #20 | M5 | Only if metrics justify | — |

**Critical path:** M0 → scheduler → M1 (model download + embedder) → M2 (API + MCP v2) → M3 → M5. **Parallel:** cloud presets/Keychain UI (#11) can start in M1; M4 runs beside M3 after the tool registry lands; docs/"Connect an app" (#12) alongside M2. Total ≈ 15–17 weeks.

## 7. Success metrics

| Metric | Target | Basis |
|---|---|---|
| First-run → first token (download excluded) | ≤ 60 s | [G] |
| First-run → first token (incl. ~8 GB download, 100 Mbps) | ≤ 15 min, with visible progress | [G]: ~11 min transfer |
| Decode tok/s, flagship model | M3 Pro 18 GB: **measure now**; publish per-tier table (M1/M2/M3/M4, Pro/Max) | Harness in M0 |
| Prefill tok/s and TTFT at 8k / 32k context | Publish; regress-gate ±10% | Harness |
| Resident memory, model loaded, idle | < 10 GB on the 16 GB tier [G] | 8 GB weights + runtime |
| Memory during 64k-context request | Must not trigger swap on 16 GB; else cap context by tier | Measure |
| Crash-free sessions | ≥ 99.5% | [G] industry norm |
| Onboarding completion | ≥ 80% of first launches reach a first reply | [G] |
| Time-to-first-integration (Claude Desktop / Cursor) | ≤ 3 min from "Connect an app" | [G] |
| Outbound requests in Local-only mode | exactly 0 | Hard requirement |

## 8. Risks

| # | Risk | Sev | Likelihood | Mitigation |
|---|---|---|---|---|
| 1 | **16 GB is tight for the 27B model** (8 GB weights + KV cache + embedder + macOS); long contexts may swap | High | High | M0 measures max safe context at 16 GB; governor (#14) caps context and routes to cloud under pressure; publish honest requirements |
| 2 | **Two inference paths** (custom Qwen3.5 for Bonsai + `mlx-swift-lm` for auxiliary models) double the MLX-upgrade surface; registry still rejects llama/gemma/etc. for chat | Med | Med | Keep `mlx-swift-lm` scoped to auxiliary models; pin `mlx-swift`; contract tests on both providers; revisit migrating Bonsai onto `mlx-swift-lm` if it gains support |
| 3 | **Prompt injection via MCP/cloud/web content** driving write/exec tools | High | Med | #10 + #18; XPC sandbox for exec; deny-by-default scopes; injection test corpus in M4 |
| 4 | **Loopback API abuse** (other local apps/malicious pages hitting 127.0.0.1) | High | Med | Off by default; bearer tokens; reject browser `Origin`/DNS-rebinding hosts; Unix socket preferred |
| 5 | **Licensing**: Bonsai weights and provider ToS (redistribution, key handling, embedding data flow) | Med | Med | Legal check before M1 ships; license acceptance UI; keys never leave Keychain |
| — | Dependency churn: `mlx-swift` (fast-moving), MCP swift-sdk (0.x), libgit2 via Homebrew | Med | High | Pin versions; vendor libgit2 for release builds (Homebrew dependency breaks notarized distribution) |
| — | Scope creep back toward an IDE | Med | Med | Non-goals list; IDE features frozen behind the tool registry |

## 9. Decisions (resolved 2026-09-28)

| # | Decision | Outcome | Notes |
|---|---|---|---|
| 1 | Lift the "no HTTP loopback" rule | **Yes** — opt-in, 127.0.0.1, per-client bearer tokens; Unix socket stays the MCP default | Update `CLAUD.md` in M0. |
| 2 | Product identity | **Stack host**; IDE features become a workspace tool pack | |
| 3 | Model strategy | **Bonsai is the only local chat model; `mlx-swift-lm` added back** for auxiliary models (embedder first) | Two inference paths accepted (risk #2). |
| 4 | Hardware floor | **16 GB.** Below it: cloud-only mode | M0 confirms usable context at 16 GB. |
| 5 | Distribution | **Developer ID + notarized DMG** (agreed); Mac App Store excluded — reasons in chat, summarized: sandbox breaks arbitrary-path file writes, spawning build tools and MCP servers, and the fixed socket path | A sandboxed "Lite" (chat + server only) is possible later. |
| 6 | HTTP stack | **Hummingbird 2 (SwiftNIO)** | |
| 7 | Telemetry | **No product telemetry; privacy enforced in code** (my call): one egress gate that every network call passes and the ledger records; Local-only mode = 0 outbound requests, tested; crash data via MetricKit stays on-device, users export a support bundle manually | Metrics in §7 come from the benchmark harness and internal testers only. |
| 8 | Weights hosting / licence | **Recommended (you said idk):** download from the source repo (Hugging Face `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`), show the licence in-app and require acceptance, store the acceptance record. We do not re-host. | Action item: read the Bonsai licence terms before M1 ships. |

---

## Executive summary

VibeCockpit already has the right skeleton: an in-process MLX runtime for a 27B ternary model, a provider protocol with OpenAI/Anthropic/Ollama adapters, a hybrid vector store, sandboxed build execution, and an embedded MCP server. What it lacks for the new vision is the *outward* surface and the *beginner* path. Today nobody else can reach the model (MCP exposes only workspace tools; there is no HTTP API), local-only users get no code search because the local model cannot embed, MCP needs `socat` and serves one client at a time, and setup means running a Python download script.

The plan is to reposition the app as a single-process, menu-bar "AI stack host": one copy of the model, a `StackCore` of actors (scheduler, router, tool registry, runtime governor), and thin adapters — the SwiftUI window, an upgraded multi-client MCP server (socket, HTTP, and a tiny stdio shim), and an opt-in OpenAI-compatible loopback API. Local is the default; cloud providers are a policy-controlled fallback with a visible egress ledger and budget caps, keys in Keychain.

Work runs in six milestones over roughly 15–17 weeks with two engineers: foundations and benchmarks (M0), zero-to-first-token onboarding with in-app downloads and an offline embedder (M1), serving over API and MCP with per-client auth and tool permission prompts (M2), cloud routing and a memory/thermal governor (M3), MCP client and prompt-injection guardrails (M4), then notarized distribution and soak testing (M5). Continuous batching and speculative decoding are deferred until measurements justify them.

Settled decisions: lift the no-HTTP rule (opt-in, loopback, tokened), stack-host identity over the IDE, Bonsai as the only local chat model with `mlx-swift-lm` for auxiliary models such as the embedder, a 16 GB floor (smaller Macs run cloud-only), notarized DMG outside the App Store, and enforced privacy with no telemetry. The biggest unknown is real memory and context headroom on 16 GB machines, which M0's benchmark harness must answer before any promise is made to users.
