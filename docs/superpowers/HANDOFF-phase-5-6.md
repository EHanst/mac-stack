# Handoff: finish the prompt sidecar (phase 5 remainder + phase 6)

## State (2026-09-29)
- `main` = PR #17 merged (`4f2938a`); local `main` synced, clean, 666 tests pass (`swift test --parallel`).
- Shipped: phase 0-4 (workbench, context pack, interview/critique), plus part of phase 5: `briefs` MCP scope (off by default) with `list_briefs`/`get_brief` (`Sources/StackMCP/Agent/BriefTools.swift`), and `BriefExporter` (`Sources/StackCore/Prompts/BriefExporter.swift`, writes `.vibe/briefs/<slug>-<id8>.md`, symlink-safe). Neither the exporter nor any versions feature has UI yet.
- Spec: `docs/superpowers/specs/2026-09-29-prompt-sidecar-design.md`. Plans: `docs/superpowers/plans/2026-09-30-prompt-sidecar-phase-{2,3,4}-*.md` (follow their style: Header, Global Constraints, Rulings, Review Focus, tasks with tests first).
- Start from a fresh branch off `main`. `/noob` (user command, `~/.claude/commands/noob.md`) lands branches safely.

## Remaining work
Phase 5:
1. Export button in the compiled pane: menu "Save to project" listing `contextSource.roots()` -> `BriefExporter.export`; show the path or error in one sentence.
2. Versions: `Brief.snapshot()` and `versions` already exist in the model. Add `BriefWorkbenchModel.saveVersion()` (skip if sections equal the last version), call it on Copy and export; `restoreVersion(_:)`; a Versions sheet showing per-section `WordDiff.segments` against the current text, with Restore. Tests first.
3. Clipboard capture: "New brief from clipboard" (goal = clipboard text, redacted only at compile time). Global hotkey (Carbon `RegisterEventHotKey`) is optional; skipped so far because it is hard to test.
Phase 6:
4. Reply loop: paste the frontier model's answer, sidecar proposes a revision of the brief (same `BriefSidecar` pattern: constant system prompt, `BriefSidecar.generationOptions` with `cacheSnapshots: false`, proposal cards, never auto-apply).
5. Continuation brief: compress a long pasted session into a new brief via `CompactionSummarizer`.
Then: final Opus whole-branch review, fix Critical/Important/Minor (user wants minors fixed too), PR, `/noob`.

## Open items
- VibeBench TTFT check after sidecar calls (spec: <=10% regression) has not been run; needs a loaded model.
- `PromptEngineer.augmentUserTurn` intentionally kept (Quick ask uses it).
- Socket MCP clients get all scopes (existing), so they get `briefs`; HTTP clients do not by default.
- Not covered: PII redaction beyond credentials; `Brief.workspace` unused.

## Gotchas
- After adding files run `xcodegen generate` (xcodeproj is gitignored), then `xcodebuild -scheme VibeCockpit -configuration Debug build`. `Scripts/dev-run.sh` builds and relaunches (may print an `open` -600 error but launches).
- `ContextRedactorTests` has a fake `sk_live_` string; GitHub push protection was allowed for it once. A new push containing such literals may be blocked again; do not obfuscate to evade it, ask the user.
- The auto-mode classifier blocks history rewrites, obfuscating secrets, and merging without review; the user must approve those explicitly.
- Concise output style; user memory: fix review minors in the same pass; skip known-slow benchmarks.
- App is menu-bar resident (bundle id `com.vibecockpit.app`); drive it with computer-use `app_*` tools; use `open` on the DerivedData app.
- Test patterns: `BriefWorkbenchModelTests.make()` builds a model with a temp `BriefStore` and `saveDelay: .zero`; `BriefSidecarModelTests` shows fake-generate + gate patterns for async cancellation.
