# Automated compaction — plan for keeping long chats inside the local context limit

**Date:** 2026-09-29 · **Status:** Draft for review · **Basis:** `prompt-studio` @ `100d707`

Legend: **[F]** fact verified in the repo · **[R]** recommendation · **[G]** guess (needs measurement).

---

## 1. Problem

`ContextBudget` computes a memory-aware `maxPromptTokens` for the local model, because a Metal OOM aborts the whole process [F: `ContextBudget.swift`]. Today an over-limit prompt is answered only by a Router fallback to cloud, or (in Prompt Studio) by dropping the shared prefix [F: `PromptOptimizer.swift`]. Nothing shortens a long conversation, so local chats end or leave the Mac once they grow.

Goal: keep a long local chat under the budget with as little loss of meaning, and as little prefill cost, as possible, without the user having to manage it.

## 2. Assumptions and open questions (ranked by impact)

| # | Assumption / question | If wrong… |
|---|---|---|
| 1 | The 2-bit local model can write a summary good enough for coding work. | Drop step 3 (summarize) for local and use elision plus cloud fallback only. **Measure first.** |
| 2 | Re-prefill after compaction is tolerable (cold prefill ≈ 82–86 tok/s on M3 Pro 18 GB [F: `model-facts.md`]; a 10k-token prompt ≈ 2 min). | Compact to a smaller target, or compact only at idle moments the user does not wait through. |
| 3 | Original messages are kept in storage; compaction changes only what is sent. | If history must shrink on disk too, add an archive step. |
| 4 | Cloud models rarely need compaction. | Reuse the same ladder with a higher threshold. |
| 5 | `maxPromptTokens` changes at runtime (Governor, memory pressure), so thresholds are fractions, not constants. | A fixed token threshold would compact too late under pressure. |

## 3. Design constraints

1. **Prefix cache.** Local speed depends on the prompt-prefix snapshot cache. Editing any earlier message invalidates it and forces a full prefill [F: `PromptLedger` is append-only for this reason]. So: compact rarely, in large steps, and keep the stable prefix (system prompt, tool definitions, pinned context) byte-identical.
2. **Rewrite once, then freeze.** The summary is stored as a real transcript message. It is never recomputed per request, or the prefix never settles.
3. **Never silent.** The UI shows "Summarized N earlier messages"; originals stay expandable. Summaries lose exact paths, identifiers and error text, which coding work needs.
4. **Untrusted content stays fenced.** Elided or summarized tool output keeps its taint status. A summary of untrusted text is itself untrusted [F: `<untrusted>` fencing, `ToolCallGuard`].
5. **Egress.** Compaction runs on the local model by default. Summarizing on a cloud model sends the history off-Mac and must go through `EgressGate` and honor Local-only.

## 4. The ladder (cheapest first)

Trigger at ~75–80% of the live `maxPromptTokens`; compact down to ~35%. These are starting values **[G]**.

| Step | Action | Model cost | Notes |
|---|---|---|---|
| 1 | **Elide bulky tool output** older than the last few turns: file reads, web results, MCP responses become a stub such as `[read Foo.swift, 3.2k tokens, elided]`. | none | Likely recovers most of the space. Re-fetchable by the agent. |
| 2 | **Summarize the oldest N turns** into one message; keep the last K turns verbatim. | one local generation | Summary prompt must preserve file paths, decisions, open TODOs and exact error strings. |
| 3 | **Fall back** to cloud (Router, as today) or ask the user to start a new chat. | none | Reached only when steps 1–2 cannot reach the target. |

User-pinned messages are never elided or summarized.

## 5. Where it plugs in

- **Pure core (`StackCore`)**: `CompactionPlanner` takes the message list, a tokenizer count, the budget and the pins, and returns a plan (which messages to stub, which range to summarize, expected tokens saved). No I/O, fully unit-testable.
- **Executor**: runs the plan; step 2 goes through `InferenceScheduler` at low priority so chat is not blocked. Runs in the idle gap after a turn completes, not before the next send.
- **Router / Governor**: the Governor can lower `maxPromptTokens` mid-session; the planner reads the live value each turn.
- **Prompt Studio**: the shared prefix is shared with chat [F]. After compaction the shared prefix is replaced by the compacted one, or the rewrite path loses its cache hit.
- **`PromptEngineer`**: its per-turn prepended addendum [F: `PromptEngineer.swift:87`] counts against the budget every turn; account for it in the trigger.

## 6. Phases

| Phase | Deliverable | Exit test |
|---|---|---|
| A | `CompactionPlanner` + token counting hook + tests | Plans are deterministic; pins and the stable prefix are never touched; untrusted taint survives. |
| B | Step 1 (elision) wired into the chat send path + UI marker | Measure how often elision alone reaches the target on real transcripts. |
| C | Step 2 (local summarization) + expandable originals | Summary keeps paths and errors on a fixed set of test transcripts. |
| D | `VibeBench` runs: TTFT and total time with and without compaction at 8k / 32k | Choose trigger and target percentages from data; regress-gate ±10%. |
| E | Cloud threshold and Governor integration | Compaction fires earlier under memory pressure; cloud chats untouched by default. |

## 7. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Summary from the 2-bit model drops critical detail | Med | High | Prefer elision; pin support; expandable originals; evaluate before shipping step 2 (Phase C). |
| Re-prefill after compaction stalls the chat for minutes | Med | Med | Compact at idle; larger, rarer steps; smaller target on slow machines. |
| Compaction evicts the prefix snapshot and slows the next turn | High | Low | Expected once per compaction; keep the stable prefix identical so only the tail re-prefills. |
| Summarizing untrusted text launders it into trusted context | Low | High | Carry the taint flag onto the summary message. |
| Summary call itself exceeds the budget | Low | Med | Chunk the range; cap input to the summarizer at half the budget. |

## 8. Decisions (chosen for performance and reliability)

| # | Decision | Why |
|---|---|---|
| 1 | **Local path: elision first; local summarization ships only if Phase C passes a quality gate** (summary keeps every path and error string on the fixed test transcripts). Until then, step 2 is off for local and step 3 (cloud fallback, or "start a new chat" when Local-only) handles what elision cannot. | A bad summary silently corrupts later answers, which is worse than a fallback. Elision costs no generation and no extra prefill. |
| 2 | **Auto-compact with a visible marker; no prompt.** Originals stay in storage and visible in the chat; only the model's copy is stubbed. **No undo:** restoring would push the prompt back over the ceiling and make `trim` drop whole turns, which is worse than the stubs. | Asking interrupts the user and does not make it safer; a visible, reversible step does. |
| 3 | **Pinning is per message** in v1. Range pinning is deferred. | Simpler planner, fewer edge cases, and no cache-stability risk from overlapping ranges. |
| 4 | **Compact only at idle, never blocking a send.** If a send arrives mid-compaction, cancel the summary and send with elision only. | Chat latency wins over tidiness. |
| 5 | **Never compact below the hard ceiling silently.** If the plan cannot reach the target, route per Router rules and say so. | An over-limit local prompt can abort the process. |

## 9. Status

| Phase | State |
|---|---|
| A | Done. `CompactionPlanner` (`Sources/StackCore/Inference/CompactionPlanner.swift`) with 10 tests. |
| B | Mostly done. `PromptLedger.elide` and the send-path call in `AppServices` (runs before `trim`, only when the local memory ceiling applies, posts a chat notice). Notice uses its own icon; undo was cut (see §8). **Left:** pinning has no UI yet, so `isPinned` is always false. Tool output is treated as untrusted. |
| C | Done, with a deterministic gate instead of a measured one. `CompactionSummarizer` (`StackCore`) builds the request (tool output fenced as untrusted, no tools offered), **extracts file paths and error lines by code and appends them verbatim**, and rejects empty, tiny or over-budget summaries. `PromptLedger.summarize` swaps the run for one assistant message only if the ledger is unchanged. `AppServices.scheduleSummaryCompaction` runs it after a turn, pinned to the local model at background priority; the next send cancels it. Only the narrative depends on the 2-bit model; paths and errors cannot be lost. **Not measured:** how good the narrative is on the real model, and whether the background prefill evicts the chat's prefix snapshot. |
| D | Done analytically (§10). Thresholds: trigger 78%, target 35%. |
| E | Done by construction. `localContextLimit()` already reads `SystemMemory.availableBytes()` on every call, so memory pressure lowers the ceiling and the planner tightens with it. Cloud-only chats (no local provider) never compact. Compaction is not disabled for a turn the Router sends to the cloud while a local model exists; that is harmless (it only shrinks history). |
| Pinning | Deferred. `Item.isPinned` is honored by the planner but nothing sets it; no UI. |

Note: `trim` (drop whole old turns at 80% of the character budget) still runs after elision and remains the last resort before the Router falls back to cloud.

## 10. Threshold derivation (Phase D)

Inputs [F: `model-facts.md`]: cold prefill 82–86 tok/s on M3 Pro 18 GB, flat in context length; snapshots resume prefill from the longest matching prefix. Eliding the oldest tool output changes text near the start, so nearly the whole kept prompt is re-prefilled once.

- **Stall after a compaction** ≈ `target × ceiling ÷ 83` s. At an 8k ceiling: target 40% ≈ 39 s, 35% ≈ 34 s, 25% ≈ 24 s.
- **Amortized overhead** per token added between compactions ≈ `target ÷ (trigger − target)` × the base prefill cost. At trigger 78%: target 40% → 1.05×, 35% → 0.81×, 25% → 0.47×.
- **Floor:** the system prompt plus the last 4 turns must fit under the target, or the planner reports `insufficient`. Lower targets hit that floor sooner.

35% is the pick: about 20% less stall and 25% less amortized overhead than 40%, without going low enough to hit the floor on ordinary chats. Re-measure with `VibeBench` if the model, chunk size or hardware changes. The existing `trim` still handles anything elision cannot reach, at the same re-prefill cost.

## 11. Refinements after the real-chat run

Measured with `VibeBench --long-chat-test --ceiling 6000` (15 sends about this repo's own files, M3 Pro 18 GB):

| | first version | with refinements |
|---|---|---|
| Compaction events | 4 (turns 7, 9, 11, probe) | **1** |
| Replies stalled by a cache miss | 4 × 32–38 s (~140 s) | **0** |
| Ordinary turn | ~7 s, cache hit | ~7 s, cache hit |
| Reply right after compaction | 34–38 s (full re-read) | **6.1 s** (1,544 of 1,551 tokens cached) |
| GPU work done while idle | 2 summaries, ~50 s | 1 summary + re-read, 95 s (75 s summary, 19.5 s re-read) |
| Recall probes (name, "the first file", ordered list) | 1 of 3 wrong | **3 of 3 right** |

What changed: token counts are calibrated from the model's own numbers (3.97 chars/token measured vs 2.5 assumed); the protected recent window shrinks when it can't reach the target; clearing and summarizing happen in one step after the turn; the new prompt is read in the background right afterwards; summaries are numbered ("Part 1 is the oldest") and ordered; summary requests don't touch the prefix cache.

Not measured: sending a message *during* the idle work (cancellation path), battery/thermal cost of the idle work, and behavior on a machine with a much larger or smaller ceiling.
