# Single-pane Brief — Design

**Status:** approved 2026-09-30 · **Branch:** `feat/single-pane-brief` · **Supersedes:** the sectioned workbench in `2026-09-29-prompt-sidecar-design.md` (phase 2 layout) and the Synthesize mode.


User request: adjust the cluttered Briefs interface back to simple roots. Remove the per-section input boxes (Goal/Context/Constraints/Examples/Output format) and collapse into ONE input pane. Input updates the brief live. Users can directly edit the brief. Remove Synthesize entirely. Move Improve onto the brief.

User decisions: (1) Instant deterministic compile + edit lock (no model per keystroke). (2) Remove Synthesize EVERYWHERE. (3) Keep Sidecar rail (Ask me / Critique / Paste reply), retargeted to the single input.

Key finding: with one free-text input and instant compile, the brief ≈ input + redaction + target formatting + context attachments. Improve is the step that structures the brief; until edited/improved the brief is "linked" and mirrors the input.

1. Data model — Brief schema v2 (Brief.currentVersion = 2)
- `input: String` replaces `sections: [BriefSection]`. BriefSection type deleted.
- `body: String?` — nil = linked (brief follows input); non-nil = edited (user owns it; input changes never overwrite).
- `contextItems`, `target`, `versions`, title, workspace, dates kept. `Version` stores `input: String` and `body: String?`.
- Migration from v1: custom `init(from:)` decodes v1 `sections`; enabled non-empty sections joined into `input` as "## Goal\n…\n\n## Context\n…" (titles: Goal, Context, Constraints, Examples, Output format); body = nil; v1 versions migrated the same way. BriefStore: before the first v2 write of a brief loaded from a v1 file, copy the original file to `<id>.v1.json` (never overwrite an existing backup; backup files must be ignored by load()). Future schemaVersion > current still skipped.
- Accessor `effectiveBody: String { body ?? input }`.

2. Compile (pure, sync, instant)
- `BriefCompiler.compile` = redact(effectiveBody) + context attachments rendered per target format (xml `<file path=…>` or fenced markdown; `.reference` → "See <ref>"). Existing budget downgrade/drop/overBudget logic unchanged (sectionsOverBudget → bodyOverBudget).
- Per-section tag wrapping and plainNumbered constraint numbering removed. Context items are included whenever `item.included` (no context-section toggle anymore). `emptyGoal` warning → `emptyInput` (effective body is whitespace).
- Compiled text is never persisted.

3. Layout
- Center (BriefWorkbenchView): header unchanged (picker, New menu, delete), continuation status, KnowledgePromptView, then the input pane, inlined in BriefWorkbenchView (no separate `BriefInputPane` type): one large editor for `input`, ContextListView chips, SidecarRailView, PromptLint findings for the input.
- Right (CompiledPromptPane → renamed/reworked as `BriefPane`): target picker, token meter, status line "Linked to input" / "Edited · Rebuild from input", toolbar with **Improve**, editable body editor (shows effectiveBody), read-only attachments footer listing included context items (ref + tokens + mode), warnings, existing copy bar (Copy, Copy for…, Save to project, Versions).
- Context file contents are NOT in the editable text.
- Both editors reuse the echo-guard editor (rename `SectionTextEditor` → `EchoGuardedEditor`, move to its own file) to avoid cursor jumps.

4. Ownership rules
- Typing in the brief editor while linked: `body = edited text` → edited. Editing body to exactly equal input does NOT auto-relink (explicit only).
- Typing in the input while edited: body untouched; model exposes `inputChangedSinceEdit: Bool` (true when input changed after body was set) → hint "Input changed since you edited the brief".
- `rebuildFromInput()`: snapshot a version first (undo via Versions), then body = nil.
- Improve: runs PromptStudio `.improve` on effectiveBody. Accept → setBody (edited). Expand and "Ask questions" remain in the review sheet; Q/A lines append to the body.
- Restoring a version restores both input and body.

5. Sidecar retargeted
- BriefSidecar prompts drop per-section tags; the brief is sent as `<brief>` with the active text (`effectiveBody`) only, since revisions replace only the active text. Interview answers, critique "Add this" and revisions apply to the active text (input while linked, body while edited; see D2). Revise returns one `<revision>` block: a whole-text replacement, shown as a diff. Question/Finding/Revision types drop `section`.
- KnowledgeRecorder records effectiveBody (guard: non-empty). KnowledgeRetriever uses of sections updated.
- BriefVersionDiff compares input and body instead of per-section rows.
- MCP `get_brief` keeps returning only the compiled prompt; `list_briefs` marks edited briefs (see D9).
- BriefSidecarModel.continueFromSession / newBrief(title:goal:context:) → newBrief(title:input:).

6. Synthesize removal (everywhere)
- Delete `OptimizeMode.synthesize`, `OptimizeContext.reference`, `wrapReference`, `<reference>` fencing in userBody, PromptStudioModel.startOptimize `reference:` param.
- IntentPane: remove Synthesize button, synthesize(asSent:), auto-synthesize-on-send toggle and its state. PromptInspectorSheet: remove onSynthesize and its button. OptimizeReviewSheet: remove onSynthesize + buttons.
- MCP optimize_prompt: enum ["improve","expand","adapt"]; unknown mode returns an explicit error (today silently defaults to improve — fix).
- VibeBench: default modes ["improve"], remove synthesize from lookup and loops.
- Delete/adjust synthesize tests.

7. Antipatterns avoided: two writers without an owner; persisting derived text; lossy migration; feature flag running old+new UI in parallel (single cutover); model calls per keystroke; growing the 245-line view (split files); leftover dead code (compiler-driven removal); silent default on bad MCP input.

8. Testing: Swift Testing (`import Testing`, @Test, #expect), run with `swift test --filter <Suite>`; full `swift test --parallel`. Compiler tests (linked vs edited, redaction, context both formats, emptyInput), migration tests (v1→v2 join, disabled sections preserved in backup, backup not re-loaded as a brief, future schema skip), workbench ownership tests, sidecar `<revision>` parse, MCP unknown-mode error, compile perf check with 200 KB diff item < 16 ms (memoize redaction only if it fails). Final: launch app with the run-vibecockpit skill and visually verify.

9. Corrections from plan review

- **D1 Edit tracking.** `Brief` stores `inputAtEdit: String?`, the input at the moment `body` was first set. `inputChangedSinceEdit` compares against it, so the "input changed" hint survives relaunch. `Version` stores it too, so restore is exact.
- **D2 Sidecar targets the active text.** Answers, "Add this" and revisions apply to `input` while linked and to `body` while edited. Otherwise, after Improve (always edited) sidecar actions would change nothing visible.
- **D3 Renames.** `.emptyGoal` becomes `.emptyInput` and `.sectionsOverBudget` becomes `.bodyOverBudget` on `BriefWarning`, `SidecarError` and `BriefExportError`.
- **D4 MCP errors.** `AgentToolError` gains `invalidArgument(name, reason)`. `optimize_prompt` rejects unknown modes; it used to fall back to improve silently. The mode parser is a static function, so it's testable without inference.
- **D5 Perf gate.** The unit test asserts < 100 ms (best of 3) in debug as a regression guard. The 16 ms frame target is a manual release-build check.
- **D6 Backups.** `<id>.v1.json` is written once, before the first v2 write; it's never overwritten and never loaded. Deleting the brief deletes its backup, because leaving a hidden copy of possibly secret text is worse.
- **D7 Types.** The legacy decode types are file-private and `BriefSection` is deleted.
- **D8 Compile.** Context items are included whenever `item.included` (there's no context toggle any more). Item rendering and `</file` neutralization are unchanged.
- **D9 MCP contract.** `get_brief` still returns only the compiled prompt: MCP clients rely on "ready to follow". `list_briefs` marks edited briefs with "· brief edited".



## Amendment 2026-09-30: Improve flow

Supersedes decision 3 ("keep Sidecar rail: Ask me / Critique / Paste reply"):

- Ask me and Critique are removed from the UI. Paste reply stays. The interview/critique operations stay in `BriefSidecar` for `KnowledgeEval` and `VibeBench`.
- Cmd+Return in the Input runs Improve (same sheet as the Improve button). Plain Return stays a newline.
- A feedback bar under the brief edits the body directly from a plain-language instruction (`BriefSidecar.edit`), with Undo (`BriefFeedbackModel`). Edits that drop code, paths, quoted text or numbers are refused.
- A brainstorm banner above the rail shows up to 2 questions and 2 tips (`BriefSidecar.brainstorm`), refreshed after a 2 s debounce once the brief is edited, and on demand.
