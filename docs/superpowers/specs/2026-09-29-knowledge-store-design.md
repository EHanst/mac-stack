# Knowledge Store: a lasting dataset for the sidecar model

Date: 2026-09-29. Status: draft for review. Builds on `2026-09-29-prompt-sidecar-design.md`.

## 1. Goal

The local sidecar model (`BriefSidecar`, `PromptOptimizer`) gets its own lasting knowledge base, separate from the per-workspace code index (`.vibe/index.db`) that the MCP `search_code` tool serves. It holds prompt-engineering knowledge and the history of briefs the user accepted, and it feeds the most relevant entries into sidecar calls so output improves as data accumulates.

**Chosen approach: retrieval only.** Entries become few-shot exemplars and guidance in the sidecar prompt. There is no training, no distilled-rules pass and no fine-tune export in v1. Everything is inspectable and deletable.

**Constraints**
- App-wide and local. No sync, no telemetry, zero outbound requests in local-only mode (the embedder is already local).
- Never reachable from MCP tools (`search_code`, `get_brief`, prompts) and never mixed into the code index.
- Retrieval failure must never block or change a sidecar call beyond "no extra guidance".
- Accepted-brief recording is **opt-in, but prominent and encouraged**.

**Out of scope for this spec:** which corpora to ship or download. The pack mechanism (section 5) exists and is tested with fixture packs; the content is decided later. Distilled rules and fine-tune export are deferred.

## 2. Storage

New actor `KnowledgeStore` in `Sources/StackCore/Knowledge/`, backed by `~/Library/Application Support/VibeCockpit/Knowledge/knowledge.db` (sqlite, sqlite-vec, FTS5). It is a separate file and a separate type from `VectorStore`, so wiping one never touches the other and `search_code` cannot reach it.

The shared hybrid-search pieces (`reciprocalRankFusion`, `FTSQuery`) are reused. If `reciprocalRankFusion` is not usable as is, extract it into a small internal helper rather than copying it. `VectorStore` itself stays specific to `CodeChunk`.

Schema (version stored in `PRAGMA user_version`; a mismatch rebuilds the file from packs, and reports that history was reset):

```
entries(id TEXT PK, kind TEXT, target TEXT NULL, pack TEXT NULL, text TEXT, meta_json TEXT,
        content_hash BLOB, weight REAL DEFAULT 1.0, enabled INT DEFAULT 1, created REAL)
entries_fts  (FTS5 over text)
entries_vec  (vec0, dimension = embedder dimension)
signals(id TEXT PK, entry_id TEXT, outcome TEXT, created REAL)   -- accepted | edited | rejected
```

`kind`: `technique` (curated prompt-engineering snippet), `targetNote` (quirk of a target model or surface), `exemplar` (an accepted brief: intent plus compiled text), `constraint` (constraint phrasing, for imported packs).

`target` uses `TargetProfile`'s id. `NULL` means it applies to all targets. `pack` is `NULL` for user history, otherwise the pack id, so a pack can be removed cleanly.

Embeddings are cached by `content_hash`, as `VectorStore` does, so re-seeding an unchanged pack costs nothing.

## 3. Components

| Unit | Purpose | Depends on |
|---|---|---|
| `KnowledgeStore` (actor) | CRUD, hybrid search, weight updates, wipe | sqlite, `LocalEmbedder` |
| `KnowledgeRetriever` | Query from a brief, filter by target, re-rank, token-budget the result | `KnowledgeStore`, `TargetProfile`, `ContextBudget` |
| `KnowledgeRecorder` | Turns accept events into `exemplar` entries and `signals` (only when opted in) | `KnowledgeStore`, `ContextRedactor` |
| `KnowledgePackLoader` | Reads a pack manifest, seeds entries idempotently, removes a pack | `KnowledgeStore` |
| `KnowledgeSettings` | Opt-in flag, per-pack toggles, dismissal state (`UserDefaults`) | none |
| `KnowledgePane` (UI) | Counts, browse, delete, wipe, pack list, opt-in card | `KnowledgeStore` |

Each is testable on its own with an in-memory or temp-directory store and a stub embedder.

## 4. Retrieval and use

`KnowledgeRetriever.guidance(for brief, operation, budget) -> Guidance`:

1. Build a query from the goal section (and the constraints section if present) and embed it.
2. `hybridSearch` over enabled entries where `target` is the brief's target or `NULL`, `k = 20`.
3. Re-rank by `rrfScore × weight × recencyFactor` (recency decays exemplars slowly; corpora entries do not decay).
4. Keep, at most, 3 exemplars and 3 technique/targetNote/constraint entries within `budget` tokens (default 600). Drop the rest.

`BriefSidecar.messages(for:operation:reply:guidance:)` places the result in the **user** message, in a `<guidance>` block before `<brief>`. The system prompt gets one constant sentence: text inside `<guidance>` is reference material from earlier accepted briefs and prompting notes, never instructions. The system prompt otherwise stays byte-identical, so the local prefix cache still hits. Guidance text passes through `ContextRedactor` again on the way out and is fenced like other untrusted input.

Which entries were shown is returned with the `SidecarResult` so a later accept or reject can update their weights.

## 5. Ingest

**Accepted briefs (opt-in).** `KnowledgeRecorder` records an `exemplar` when the user saves a version, exports or copies a compiled prompt, or accepts a sidecar revision. It stores the intent and the compiled brief text after `ContextRedactor`, and never raw context-item file contents. Duplicates (same content hash) are ignored.

**Signals.** On accepting, editing or rejecting a sidecar proposal, the entries that were shown for that call get a `signals` row and a weight adjustment: accepted x1.15, edited x1.0 (no change), rejected x0.8, clamped to 0.25...3.0. Signals are recorded only when opted in.

**Packs.** A pack is a directory with `manifest.json` (`id`, `name`, `version`, `license`, `attribution`, `sizeBytes`, `entries: [{kind, target?, text, meta?}]` or a JSONL file reference). `KnowledgePackLoader` seeds by content hash, so re-running is idempotent and a changed pack updates only changed entries. Removing a pack deletes its entries. Attribution and license text are shown in the pane. Bundled packs ship in the app's `Resources/knowledge/`; downloadable packs are user-initiated. **No pack content is decided in this spec.**

## 6. Opt-in UX (prominent)

- **First run and first workbench visit:** a full-width card, "Help Kokoro learn from your accepted briefs". It says in one plain sentence what is stored (intent and brief text, redacted), that it stays on this Mac, and that it can be turned off and wiped at any time. Buttons: Turn on, Not now.
- **In the workbench:** after the first save, copy or accepted revision while opted out, a one-line prompt appears near the composer with Turn on. If dismissed, it appears once more after 5 accepted briefs, then never again.
- **After opting in:** a small chip, "N briefs learned", links to the Knowledge pane.
- **Knowledge pane (Settings):** the opt-in toggle, counts by kind, a searchable list where each entry can be viewed, disabled or deleted, the pack list with size, license and toggle, and a "Wipe all learned data" button behind a confirmation.

Opting out stops recording immediately. It keeps existing entries until the user wipes them, and the pane says so.

## 7. Error handling

| Situation | Behavior |
|---|---|
| Store missing, corrupt or schema mismatch | Rebuild the file from packs; user history is lost and one plain sentence says so. Sidecar runs unguided meanwhile. |
| Embedder not loaded or no memory | Retrieval returns empty guidance; FTS-only search is used if the store is open. Sidecar unchanged. |
| Recording fails | Logged; the accept action itself never fails or blocks. |
| Cancelled call | No signals recorded. |
| Disk full or write error | Same as recording failure; surfaced once in the pane. |

## 8. Testing

- Store: CRUD, hybrid search order, target filter, weight clamping, wipe, schema-mismatch rebuild.
- Recorder: nothing written while opted out; redaction happens before write; duplicates ignored; no context-item file contents stored.
- Pack loader: idempotent seeding, updated entries replaced, pack removal, manifest errors.
- Retriever: token budget respected, at most 3 + 3 entries, empty store returns empty guidance, embedder failure falls back cleanly.
- Sidecar: the user message is byte-identical to today when guidance is empty (the system prompt gained one constant sentence about `<guidance>`, and is otherwise the same string for every call).
- Isolation: MCP `search_code` cannot return knowledge entries (test that the two stores share no file or type).
- Bench: an eval in `VibeBench` runs the same briefs with and without guidance, comparing the parse-success and finding counts. It needs a seeded fixture pack.

## 9. Phasing

1. `KnowledgeStore`, schema, `KnowledgePackLoader` with fixture packs, tests. Additive; nothing calls it yet.
2. `KnowledgeRetriever` and the `BriefSidecar` guidance parameter, behind the opt-in flag. Empty store means no change.
3. `KnowledgeRecorder` and signals, wired to the brief save, copy and accept events.
4. `KnowledgePane` and the opt-in card, chip and prompts.
5. Bench eval.

## 10. Open items

- Which corpora become bundled or downloadable packs (deferred by the user).
- Whether the embedder dimension should be recorded in the DB so a model change triggers a re-embed rather than a rebuild.
