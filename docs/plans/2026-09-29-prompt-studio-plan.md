# Prompt Studio — plan for a first-class prompt-management feature

**Date:** 2026-09-29 · **Status:** Draft for review · **Basis:** `m5-ship` @ `24a728f`

Legend: **[F]** fact verified in the repo · **[R]** recommendation · **[G]** guess (needs measurement).

---

## 1. Assumptions and open questions (ranked by impact)

| # | Assumption / question | If wrong… |
|---|---|---|
| 1 | "Improve poor inputs before integration" means: **before the draft is sent to the model and before RAG and task framing are added to it**. | If it means "before merging into a saved prompt", the optimize button moves into the library editor only. |
| 2 | **Optimize is always user-triggered and reviewed.** It never sends anything itself. A "suggest as I type" mode is a later opt-in. | Silent auto-rewrite would change user intent with no audit trail. |
| 3 | The optimizer runs on **the model the user has selected** by default, with an optional "use this model to optimize" override. | If a fixed optimizer model is wanted, we must pick one and budget its memory. |
| 4 | "Utility models" = anything without `.textGeneration` (today: the bge-small embedder [F]) or with `.speculativeDraft` [F: capability exists]. Every other connected provider, local or cloud, gets the feature. | A future utility model with `.textGeneration` needs an explicit `isUtility` flag. |
| 5 | Prompts are **personal by default** and can optionally live **inside a workspace** (`.vibe/prompts/`) so a team can commit them. | Repo-committed prompts need a trust rule (see §6). |
| 6 | The assistant is named **Kokoro**. The optimizer's *notes* speak in Kokoro's voice; the *rewritten prompt* is always persona-free. | A voiced rewrite would leak "sugoi" into the model's context and into saved prompts. |

## 2. What the audit found (grounding)

| Area | State on `m5-ship` | Consequence |
|---|---|---|
| Existing "prompt engineering" | `PromptEngineer` classifies intent by **substring keyword match** [F: `"add"` matches "address", `"move"` matches "remove"] and `augmentUserTurn` **prepends a 3–6 line addendum to every user turn** [F: `PromptEngineer.swift:87`]. The user never sees it. | Two optimizers would stack. The hidden one costs context every turn and is not editable. This feature must **absorb** it, not sit beside it. |
| Prompt integrity | `PromptLedger` is append-only so the local prefix cache stays valid [F]. | The optimizer must run as a **separate one-shot request**, never through the ledger. |
| GPU | One `InferenceScheduler`, priorities exist (`.interactive`) [F]. | An optimize call queues behind or ahead of chat; it can also evict the chat's prefix snapshot [G: check `PromptSnapshotStore`]. Must measure. |
| Egress | Every outbound byte goes through `EgressGate` [F]. | Optimizing on a cloud model sends the draft off-Mac. Must honor Local-only and be logged. |
| Untrusted text | `<untrusted>` fencing + `ToolCallGuard` [F]. | Pasted web text inside a draft must be fenced when it reaches the optimizer. |
| Local speed | Decode 10.7–11.3 tok/s, cold prefill 82–86 tok/s on M3 Pro 18 GB [F: `model-facts.md`]. | A 150-token rewrite is ≈ 15–25 s locally. UX must be async and cancellable. A cheap instant tier is needed. |
| MCP | Tools only; no `prompts` primitive [F: next-phase plan §3]. | Adding `prompts/list` + `prompts/get` lets Claude Desktop / Cursor use the same library. Fits the "stack host" thesis. |

## 3. Design

### 3.1 Concepts

- **Saved prompt** — title, body with `{{variables}}`, tags, folder, pinned, optional slash name (`/review`), optional per-model variants, scope (global | workspace), version history, use count / last used.
- **Recipe** — a saved prompt the app ships or the user edits that replaces today's hard-coded per-intent addenda (`generate`, `debug`, `refactor`, `explain`, `test`, `review`, `general`). Recipes are what `PromptEngineer` applies, so they become **visible and editable**. Migration: seed the library with the current strings verbatim.
- **Model profile** — per model family: preferred structure (Claude: XML tags; GPT: markdown; Bonsai/small local: short, explicit, numbered constraints, one example), max useful prompt length, token estimator. Chosen from `ModelProvider` metadata; user-overridable.
- **Optimization** — `{ original, improved, changes: [Change], questions: [String], modelUsed, tokensIn/out }`. `Change` = one-line reason plus the span it touches.

### 3.2 Two-tier optimize

| Tier | What | Cost | Trigger |
|---|---|---|---|
| **Instant (lint)** | Deterministic, no model. Flags: vague verb with no target, no file/selection referenced, no success criterion, multiple unrelated asks, pasted error with no question, prompt exceeds the model profile's length. Shown as chips ("Add the file", "State the expected result"). | ~0 ms | Live, as you type (debounced) |
| **Deep (rewrite)** | LLM rewrite using a meta-prompt + the model profile + workspace facts. Streams into a diff view. Asks at most 2 clarifying questions when the draft is too ambiguous to rewrite honestly. | 15–25 s local [G], seconds on cloud | Button / ⌥⌘O |

### 3.3 Guardrails on Deep optimize (this is where it usually goes wrong)

1. **Never auto-send.** Result lands in a diff; user picks Accept, Edit, or Revert. Undo restores the original.
2. **Literal preservation check (programmatic, not model-judged).** Extract code fences, file paths, quoted strings, numbers, identifiers from the original; if any is missing from the output, reject the rewrite and show "Kokoro dropped something, so I kept your version" + the missing item.
3. **Length cap:** the rewrite must fit what the target can hold: on this Mac, the memory-aware context limit minus the request and a safety margin; for a cloud model, the profile's `maxUsefulTokens`. Not a multiple of the draft (changed after live testing showed a 1.5× cap rejected useful rewrites of short drafts). A rewrite over 4× the draft gets a "check it still asks for the same thing" note instead of a rejection. With under ~128 tokens of room nothing is sent.
4. **Untrusted fencing:** any text the draft marks as pasted/attached is wrapped in `<untrusted>` for the optimizer call.
5. **Egress:** if the chosen optimizer is cloud, the call goes through `EgressGate`; in Local-only mode the button falls back to the selected local model or is disabled with one sentence explaining why.
6. **Optimizer output has no tool access.** Plain text in, plain text out.

### 3.4 UI (primary interface)

- **Composer bar:** `Optimize` button, token meter (draft + RAG + framing vs context budget), `/` opens the library, `{}` chip when the prompt has variables.
- **Diff sheet:** original vs improved, per-change checkboxes (accept some, not all), Kokoro's one-line notes, Accept / Edit / Revert.
- **Library (⌘⇧P palette + sidebar):** search, tags, pinned, recents, workspace vs global. Variable form on insert. "Save this" on the composer and on **any past user message** in the transcript.
- **"What the model sees" inspector:** shows the exact system message + recipe + RAG + user text for the next send. Answers "why did it answer that way" and makes the current hidden augmentation visible.
- **Model switch:** when the user changes model, offer "Adapt this prompt for <model>" (Deep tier with the new profile).
- **Kokoro's voice:** notes and empty states only. Never in the rewritten prompt.

### 3.5 Architecture

```
StackCore (no UI, no protocol types)
  PromptLibrary        actor · JSON files in ~/Library/Application Support/VibeCockpit/Prompts/
                       (one file per prompt: human-diffable, easy export) + in-memory index
  PromptTemplate       {{var}} parse/render, built-in vars: selection, file, workspace, date, clipboard
  PromptLint           pure functions, unit-testable
  PromptOptimizer      actor · builds meta-prompt · one-shot InferenceService.generate(priority:)
                       · literal-preservation validator · returns Optimization
  ModelPromptProfile   value type · lookup by provider id/family
VibeCockpit (app)
  PromptStudioModel    @Observable · composer state, diff state, library search
  Views                Composer additions, DiffSheet, LibraryPalette, Inspector
StackMCP
  prompts/list, prompts/get   (library) · tool: optimize_prompt (scoped, off by default)
```

`PromptEngineer.classify` becomes word-boundary matching plus a visible intent chip the user can override; `augmentUserTurn` reads the recipe from the library instead of a `switch`.

## 4. Feature ideas

**Ship in v1**
1. Save / search / tag / pin / recent prompts; save any past message.
2. Variables with a fill-in form and built-ins (`{{selection}}`, `{{file}}`, `{{git_diff}}`).
3. Slash commands (`/review`, `/tests`).
4. Instant lint chips.
5. Deep optimize with diff, partial accept, undo.
6. Token/context meter.
7. "What the model sees" inspector.
8. Recipes replace the hidden per-intent text; user can edit or turn each off.

**Next**
9. Version history with diff and one-click restore.
10. Per-model variants and "Adapt for this model".
11. **Project instructions** file per workspace (`.vibe/instructions.md`) folded into the system prompt once per session (cache-safe).
12. Repo-committed prompts (`.vibe/prompts/`) with a trust prompt on first load.
13. MCP `prompts/*` so other apps share the library; `optimize_prompt` tool.
14. Import/export as Markdown with frontmatter; drag a `.md` onto the window to import.
15. "Try again with fixes" when a reply was cut off, the tool loop stalled, or the model asked a question: offers a rewritten follow-up.
16. Prompt of the day / built-in Swift starter pack (debug, refactor, tests, review, explain, SwiftUI view, actor migration).

**Later / only if metrics justify**
17. Side-by-side "run on two models" for one prompt (a simple compare, **not** an eval suite; the eval suite stays a non-goal).
18. Local-only usage stats: which prompts save time, which optimizations get accepted.
19. Clipboard/selection capture from other apps via a menu-bar hotkey.

**Cut on purpose:** prompt marketplace or cloud sync (existing non-goal, plus privacy), silent auto-optimize, model-judged "prompt score".

## 5. Phased roadmap (2 engineers; estimates [G])

| P | Goal | Deliverables | Exit criteria (measurable) | Time |
|---|---|---|---|---|
| **P0** | Kokoro persona | Persona in `buildSystemPrompt()`; optional address-name and persona on/off settings | System prompt ≤ 200 tokens; identical across turns in a session (cache test) | 1 d |
| **P1** | Core library | `PromptLibrary`, `PromptTemplate`, recipes migrated from `PromptEngineer`, word-boundary classifier | Existing `PromptEngineerTests` pass unchanged on seeded recipes; CRUD/versioning/variable tests green | 1 wk |
| **P2** | Composer UI | Save, slash palette, variables form, token meter, inspector | Save → reuse in ≤ 3 clicks; inspector output equals the ledger's last user message byte-for-byte | 1.5 wk |
| **P3** | Optimizer | Lint chips, Deep rewrite, diff sheet, guardrails, egress + untrusted handling | Preservation validator rejects 100% of a seeded set of dropped-literal outputs; Local-only mode makes **0** outbound requests; cancel returns the composer in < 500 ms | 1.5 wk |
| **P4** | Per-model | Profiles, "Adapt for this model", utility-model exclusion | Embedder never appears as an optimizer; profile chosen for Bonsai vs a cloud model in tests | 1 wk |
| **P5** | Share | MCP `prompts/*`, `optimize_prompt`, workspace prompts + trust prompt | Claude Desktop lists and runs a saved prompt; untrusted repo prompt cannot run tools without approval | 1 wk |

Total ≈ 6 weeks. Critical path: P1 → P2 → P3. P4 and P5 can overlap once P3's optimizer interface is stable.

## 6. Risks

| # | Risk | Sev | Likelihood | Mitigation |
|---|---|---|---|---|
| 1 | A 2-bit local model rewrites badly or changes intent | High | Med [G] | Diff + accept, literal-preservation check, measure acceptance and drop-rate on a fixed set in `VibeBench` before enabling Deep by default on local |
| 2 | Optimize call **evicts the chat's prefix cache**, slowing the next real turn | Med | Med [G] | Measure TTFT of the next chat turn with vs without an optimize call (±10% gate); keep optimizer prompts short; consider a separate snapshot slot |
| 3 | Optimizer latency feels broken (15–25 s) | Med | High | Streaming diff, cancel, Instant tier does most of the work, cloud option under policy |
| 4 | Hidden augmentation and visible optimization disagree | Med | High | Recipes absorb `PromptEngineer`; inspector shows the final text |
| 5 | Repo-committed prompts smuggle instructions | High | Low | Treated as untrusted until the user opens and approves them; no tool grants from a prompt file; variables expand only from an allow-list |
| 6 | Draft (with proprietary code) sent to a cloud optimizer | High | Med | `EgressGate`, visible notice, default to the selected local model |
| 7 | Persona bleed into saved or rewritten prompts | Low | Med | Optimizer meta-prompt forbids it; validator strips known persona tokens; tests |

## 7. Success metrics

| Metric | Target |
|---|---|
| Save-and-reuse a prompt | ≤ 3 clicks / ≤ 5 s |
| Instant lint latency | < 50 ms |
| Deep optimize, first streamed token, cloud / local | < 2 s / < 8 s [G] |
| Optimization acceptance rate (local, own usage) | ≥ 50% accepted at least in part [G] |
| Literal-preservation failures reaching the user | 0 |
| Next-turn TTFT regression after an optimize call | ≤ 10% |
| Outbound requests in Local-only mode | exactly 0 |

---

## 8. Implementation status (2026-09-29)

P0–P5 are built on branch `prompt-studio`; the full test suite passes and the Xcode app target builds. Checked by eye in the running app: the chat box tools (Improve, Prompts, task chip, token count, hint chips) and the Prompts page. Not yet exercised in the running app: a real Improve round trip through the UI, the review sheet, saving from a message, project prompts.

### Measured (VibeBench `--studio-test`, Bonsai-27B, M3 Pro 18 GB, ~1,600-token conversation)

| Scenario | Improve call | Next chat message |
|---|---|---|
| No Improve call (baseline) | – | TTFT 1.25 s, 46 tokens prefilled |
| Improve as a **separate prompt** | 3.8 s, 293 prefilled | **TTFT 19.8 s, all 1,631 tokens prefilled** (cache lost) |
| Improve **continuing the conversation** (shipped) | 4.7 s, 347 prefilled | **TTFT 0.86 s**, 19 prefilled |

Risk 2 was real: `PromptSnapshotStore.prune` drops every snapshot that isn't a prefix of the prompt just served, so an unrelated prompt wipes the chat's cache (16× slower next message; about 100 s at 8k tokens). A rewrite by a model on this Mac therefore continues the conversation (a final user message carries the instructions and draft), which also pre-warms the next turn. A cloud model, or a conversation too long for the local window, gets the self-contained draft-only request instead, so the conversation never leaves the Mac.

### Deviations from the plan

- **Partial acceptance:** per-change checkboxes aren't possible because the rewriter reports changes as one-line notes, not text spans. The review sheet shows a word-level diff, lets the user edit the rewrite before accepting, and offers Keep mine / Expand / Use this.
- **Built-in blanks:** `{{workspace}}`, `{{date}}`, `{{clipboard}}` fill themselves in the app; `{{selection}}`, `{{file}}`, `{{git_diff}}` are asked for (the app has no editor selection to read). Over MCP, `{{clipboard}}` is never read for outside apps.
- **New permission:** `prompts` ("Read your saved prompts"), off by default for new apps.
- **Not built:** project instructions file (idea 11), side-by-side model compare, local usage stats, hotkey capture (later/next lists).
- **Improve tolerance:** a rewrite that differs only in capitalisation, spacing or a final full stop is reported as "already clear".
- **Known flaky, unrelated:** `ModelInstaller` "installs the included files" failed once under the full parallel run (`sizeMismatch`) and passed in 3 isolated reruns.


## Addendum: editable Kokoro personality
Settings → Kokoro now has a **Personality** text box (default: Kokoro's voice). The user can rewrite or rename it; blank or unchanged stores nothing so the default keeps improving. Only the personality is editable: the core rules (correctness, safety, native-Swift stack, "never use the voice in code, diffs, commit messages, tool arguments or file contents") are appended after it and always apply. Custom text is capped at 600 characters (~150 tokens) because it rides along with every conversation and eats local context. Off toggle still gives the plain assistant line. Applies to new conversations (system prompt is built once for the prefix cache).
