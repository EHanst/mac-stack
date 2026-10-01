# Brief panel: Human / Machine toggle

## Goal
Replace the Brief panel's Preview/Edit tabs with one always-editable markdown editor and a Human / Machine toggle. Machine is a read-only, token-optimized render shaped by the destination model's profile.

## UI (`Sources/Kororo/UI/Briefs/BriefPane.swift`)
- Remove `ViewMode.preview/.markdown` and the Preview `MarkdownText` branch.
- Human: `EchoGuardedEditor` bound to `model.setBody`, monospaced, always editable.
- Machine: read-only monospaced text of `BriefCompiler.compile(brief, compact: true).text`.
- Toggle: segmented Human | Machine. Reuse AppStorage key `brief.viewMode`; legacy "Preview"/"Edit" values map to Human.
- Token meter, savings %, "Copy for machine" and "Copy" are unchanged. Copy copies the Human form.
- Out of scope: Improve workspace tabs (`ImproveWorkspaceView`).

## Machine format (`Sources/StackCore/Prompts/BriefCompiler.swift`)
`renderCompact` takes the target's `ModelPromptProfile.structure`:
- `.xmlTags`: `<task>…</task>`, `<file p="path">…</file>`, `<ref p="path"/>`. No legend line.
- `.markdown`: `# task`, `# file <path>` with fenced blocks, terse list for requirements. No legend line.
- `.plainNumbered`: current `#FMT/#TASK/#FILE/#REF` markers, constraints numbered.
Shared and unchanged: redaction, budget downgrade/drop, warnings, `compactProse`, fence passthrough, `</file` neutralization (applied in the XML form), one-line paths.
Machine is derived only; there is no reverse parsing.

## Tests (write first)
- Per structure: expected tag shape, literals preserved, tokens < human form.
- Deterministic output for the same brief.
- XML form neutralizes `</file`.
- Legacy viewMode values migrate to Human.
- Update existing compact and `TokenSavings` tests.

## Evaluation
No meta-prompt, sampling or validator change, so the optimizer eval is not run. Report per-structure token savings from tests.
