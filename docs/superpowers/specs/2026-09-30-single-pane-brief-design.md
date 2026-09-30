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
- Center (BriefWorkbenchView): header unchanged (picker, New menu, delete), continuation status, KnowledgePromptView, then `BriefInputPane`: one large editor for `input`, ContextListView chips, SidecarRailView, PromptLint findings for the input.
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
- BriefSidecar prompts drop per-section tags; the brief is sent as `<brief>` with input (and body if edited). Interview answers and critique "Add this" append to the input. Revise returns one `<revision>` block: whole-input replacement, shown as a diff, applied via `setInput`. Question/Finding/Revision types drop `section`.
- KnowledgeRecorder records effectiveBody (guard: non-empty). KnowledgeRetriever uses of sections updated.
- BriefVersionDiff compares input and body instead of per-section rows.
- MCP BriefTools get_brief/list_briefs return `input`, `body` (or null), `compiled`.
- BriefSidecarModel.continueFromSession / newBrief(title:goal:context:) → newBrief(title:input:).

6. Synthesize removal (everywhere)
- Delete `OptimizeMode.synthesize`, `OptimizeContext.reference`, `wrapReference`, `<reference>` fencing in userBody, PromptStudioModel.startOptimize `reference:` param.
- IntentPane: remove Synthesize button, synthesize(asSent:), auto-synthesize-on-send toggle and its state. PromptInspectorSheet: remove onSynthesize and its button. OptimizeReviewSheet: remove onSynthesize + buttons.
- MCP optimize_prompt: enum ["improve","expand","adapt"]; unknown mode returns an explicit error (today silently defaults to improve — fix).
- VibeBench: default modes ["improve"], remove synthesize from lookup and loops.
- Delete/adjust synthesize tests.

7. Antipatterns avoided: two writers without an owner; persisting derived text; lossy migration; feature flag running old+new UI in parallel (single cutover); model calls per keystroke; growing the 245-line view (split files); leftover dead code (compiler-driven removal); silent default on bad MCP input.

8. Testing: Swift Testing (`import Testing`, @Test, #expect), run with `swift test --filter <Suite>`; full `swift test --parallel`. Compiler tests (linked vs edited, redaction, context both formats, emptyInput), migration tests (v1→v2 join, disabled sections preserved in backup, backup not re-loaded as a brief, future schema skip), workbench ownership tests, sidecar `<revision>` parse, MCP unknown-mode error, compile perf check with 200 KB diff item < 16 ms (memoize redaction only if it fails). Final: launch app with the run-vibecockpit skill and visually verify.
