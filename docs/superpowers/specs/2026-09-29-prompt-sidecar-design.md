# Prompt Sidecar — repositioning VibeCockpit as a prompt engine for frontier models

**Date:** 2026-09-29 · **Status:** Approved design, awaiting spec review · **Basis:** `feat/hide-builtin-embedder`

## 1. Purpose

VibeCockpit stops being a local chat assistant / coding IDE and becomes a **sidecar for frontier models** (Claude Code, Cursor, ChatGPT, Claude Desktop). Its one job is to produce the best possible prompt for them. The primary artifact is a **Brief**: a structured, versioned prompt compiled for a specific target model and surface.

Why a sidecar beats the frontier chat box: it knows the repo (RAG index, AST chunks, git state), iterates for free and in private on the local model, and shapes the prompt for the exact model and surface it is going to.

### Decisions (from the user)

| # | Decision |
|---|---|
| 1 | Code-first. Repo-aware briefs are the core; general-domain prompts are secondary. |
| 2 | Chat is interview-only, plus a small quick-ask box. |
| 3 | IDE features (agent loop, `write_file`, `run_build`, snapshots, diff, preview) leave the UI but stay available over MCP. |
| 4 | Handoff is copy, file and MCP. No cloud dispatch in v1. |
| 5 | Kokoro is toned down: voice only in short notes and empty states, not in the interview system prompt; rewritten prompts stay persona-free. Subtitle "AI Coding IDE" becomes "Prompt sidecar". The name VibeCockpit stays unless changed later. |

### Non-goals (v1)

Sending briefs to cloud APIs from the app, A/B eval suites, prompt marketplace or sync, silent auto-optimization, model-judged prompt scores, deleting the MCP agent tools.

## 2. Grounding (what exists today)

Reused as-is or extended: `PromptOptimizer` (modes improve/expand/adapt, literal-preservation check, shared-prefix continuation), `PromptLint`, `PromptTemplate`, `PromptLibrary`/`SavedPrompt` (versions, model variants), `ModelPromptProfile`, `WordDiff`, `PromptInspectorSheet`, `OptimizeReviewSheet`, `WorkspacePrompts`, `EgressGate`, `UntrustedContent`, `CompactionSummarizer`, MCP `prompts/*` and `optimize_prompt`, workspace RAG (`VectorStore`, `ASTChunker`), `GitSnapshotManager`.

Replaced or retired from the UI: `IntentPane` as the center, the hidden `PromptEngineer.augmentUserTurn`, `intentHistory` as primary state, the Changes/Snapshots/Preview panes, the "AI Coding IDE" framing.

Measured constraint (`docs/plans/2026-09-29-prompt-studio-plan.md` §8): an unrelated one-shot request evicts the chat's prefix cache (next-turn TTFT 0.86 s becomes 19.8 s). Local decode is about 11 tok/s.

## 3. Design

### 3.1 Data model (`StackCore/Prompts`)

- `Brief`: `id`, `title`, `workspace`, `target: TargetProfile`, ordered `sections`, `contextItems`, `versions`, timestamps.
- `BriefSection`: `kind` (goal, context, constraints, examples, outputFormat), `text`, `enabled`.
- `ContextItem`: `kind` (file, symbol, gitDiff, snippet), `ref`, `mode` (inline | reference), `tokens`, `included`, `provenance` (the search or path it came from).
- `TargetProfile`: extends `ModelPromptProfile` with a `surface` (claudeCode, cursor, chatGPTWeb, claudeDesktop, other). The surface sets the default context mode (Claude Code reads files itself, so reference; ChatGPT web cannot, so inline).
- Storage: one JSON file per brief under Application Support (same pattern as `PromptLibrary`), exportable to `.vibe/briefs/*.md`.

### 3.2 Compiler (pure, no model calls)

`compile(brief, target) -> CompiledPrompt { text, tokens, estimatedCost, warnings }`.

- Stable content first, volatile last, to favor provider prompt caching.
- Structure follows the profile (XML tags or Markdown).
- Over budget: first downgrade inline items to references, then drop the lowest-priority items. Every change is a warning; nothing is dropped silently.
- Deterministic, so golden-file tests per profile are possible.

### 3.3 Sidecar model operations

Operations: interview (at most 2 or 3 gap questions), critique (ambiguity, contradictions, missing acceptance criteria), adapt (restyle for the target).

- One `BriefSession` per brief owns a shared prefix; every call continues it so the prefix cache survives.
- Output is always a proposal shown as a diff. The user accepts it; it never writes into the brief unprompted.
- Existing guardrails apply: literal preservation, `<untrusted>` fencing, `EgressGate`, lint, no tool access for the rewriter.
- Kokoro voice is limited to notes and empty states.

### 3.4 UI

`BriefWorkbenchModel` (`@Observable`) replaces the chat state in `IntentPane`.

- Left: Briefs and Library (fragments, recipes, templates). Navigation shrinks to Briefs, Library, Context, Models, Settings.
- Center: section editor with lint chips and per-section token counts. A narrow interview rail of question cards sits beside it, plus a quick-ask box.
- Right: the compiled prompt (what the frontier model receives), target picker, token and cost meter, diff against the previous version, Copy.
- `PromptInspectorSheet` and `OptimizeReviewSheet` are reused as the compiled pane and the proposal diff.

### 3.5 Handoff

Copy variants (plain, for Claude Code, for ChatGPT); write to file; MCP `list_briefs`, `get_brief` and `prompts/get`, behind a new `briefs` permission that is off by default (like `prompts`).

### 3.6 Errors

No model loaded, low memory, cancelled call: the brief is unchanged and one plain sentence is shown. Local-only mode makes zero outbound requests.

## 4. Features

**v1 (coherent minimum):** Brief workbench with compiled view; target = model x surface; Context Pack (pick files, symbols, git diff with per-item token cost, include/exclude, provenance, secrets/PII scan); interview; versions and diff; handoff.

**Next, in priority order:** critique pass; continuation brief (compress a long frontier session into a handoff prompt via `CompactionSummarizer`); reply loop (paste the frontier answer, get a proposed revision); cache-friendly ordering plus cost estimate; task decomposition; menu-bar hotkey capture of selection or clipboard; generators for `CLAUDE.md`/`AGENTS.md`/Cursor rules.

**Speculative:** cloud dispatch and A/B compare, outcome log, voice-to-brief.

## 5. Phases

Each phase leaves the app usable.

| Phase | Work | Code |
|---|---|---|
| 0 Reframe (about 2 days) | Rewrite framing in `CLAUD.md` and copy; hide Changes, Snapshots, Preview in the UI; subtitle change | Delete nothing |
| 1 Brief core | `Brief`, `BriefCompiler`, `TargetProfile` with tests | Additive |
| 2 Workbench UI | Editor, compiled pane, meter, copy; chat moves to the rail; remove hidden augmentation (recipes become visible sections) | Refactor `IntentPane`, `PromptEngineer`, inspector |
| 3 Context Pack | RAG picker, budget, redaction | Reuse `search_code`, index, `EgressGate` |
| 4 Interview + critique | Sections proposed by the local model, prefix-safe | Extend `PromptOptimizer` |
| 5 Handoff + versions | MCP `get_brief`, files, hotkey, diff | Extend `MCPToolHost` |
| 6 Loop (optional) | Reply revision, continuation brief | Reuse `CompactionSummarizer` |

**Riskiest step:** the prefix-cache cost of many small model calls (see §2), mitigated by the per-brief shared prefix and gated by the benchmark below.
**Point of no return:** deleting the agent loop, snapshot/diff UI, `IntentEvent` chat state or `BuildRunnerXPCService`. Not before phase 4. MCP `read_file`, `write_file`, `run_build` stay because external clients use them.

## 6. Testing and success criteria

| Check | Target |
|---|---|
| Compiler unit and golden tests per profile | All green; deterministic output |
| Over-budget behavior | Every drop or downgrade produces a warning |
| Redaction tests | Seeded secrets never appear in a compiled prompt |
| `VibeBench` scenario: next-turn TTFT after sidecar calls | Regression at most 10% |
| Local-only mode | Exactly 0 outbound requests |
| Cancel a sidecar call | Composer responsive in under 500 ms, brief unchanged |
| Brief to pasted prompt in a frontier app | At most 3 clicks |

## 7. Open items

- App name and icon: unchanged in v1 (assumption).
- Exact `surface` list and each surface's default context mode need a short review pass in phase 1.
- Whether `briefs` MCP permission ships in phase 5 or later.
