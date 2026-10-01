# Brief Human/Machine Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Brief panel's Preview/Edit tabs with an always-editable markdown editor plus a Human / Machine toggle, where Machine is a read-only render shaped by the target model's prompt structure.

**Architecture:** `BriefCompiler.renderCompact` gains a `structure` parameter and emits XML, markdown, or the current `#` markers. A small `BriefViewMode` type in StackCore owns the persisted toggle value and legacy migration. `BriefPane` shows the editor or the read-only compiled machine text.

**Tech Stack:** Swift, SwiftUI, swift-testing (`@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-10-01-brief-human-machine-toggle-design.md`

## Global Constraints

- Native Swift only; no Python/Node, no internal HTTP, no shelled git (ARCHITECTURE.md).
- No prompt text changes: `PromptPrinciples`, `PromptOptimizer` and other prompts are untouched, so the optimizer eval is not run.
- Machine text is derived only; never parsed back.
- Redaction, budget downgrade/drop, warnings, fence passthrough and one-line paths stay shared and unchanged.
- Out of scope: `ImproveWorkspaceView` tabs.
- Run `swift test` before every commit; all must pass.

## Review Focus

- Body containing `</task>` in the XML machine form must not close the `<task>` tag (neutralized like `</file`).
- Empty body in machine form: no empty `<task>` / `# task` / `#TASK` block.
- A reference item with a newline in its path stays on one line in every structure.
- Inline file text containing a triple-backtick fence in the markdown form uses a longer fence.
- A Human body that already contains its own `<task>` tag is not wrapped again in the XML machine form.
- Stored view mode of an unknown or legacy value ("Preview", "Edit", "") opens Human.

---

### Task 1: Structure-aware machine renderer

**Files:**
- Modify: `Sources/StackCore/Prompts/BriefCompiler.swift` (`compile` render closure, `renderCompact`)
- Test: `Tests/KokoroTests/BriefCompilerTests.swift` (replace `compact()` at line 249, add new tests)

**Interfaces:**
- Consumes: `ModelPromptProfile.Structure` (`.xmlTags | .markdown | .plainNumbered`), existing private helpers `compactProse`, `dropBlankLines`, `oneLine`, `attribute`, `neutralize`.
- Produces: `private static func renderCompact(_ body: String, items: [ContextItem], structure: ModelPromptProfile.Structure) -> String`. Public API unchanged: `BriefCompiler.compile(_:compact:)`.

- [ ] **Step 1: Write the failing tests.** In `BriefCompilerTests.swift`, change the existing `compact()` test to build its brief with `brief(family: "local")` (plainNumbered keeps today's output), then append:

```swift
    private func compactBrief(family: String) -> Brief {
        var b = brief(family: family)
        b.input = "## Goal\n\nFix the **login** timeout."
        b.contextItems = [
            ContextItem(id: "a", kind: .file, ref: "A.swift", text: "let a = 1\n\n\nlet b = 2", mode: .inline),
            ContextItem(id: "b", kind: .file, ref: "B\n.swift", text: "x", mode: .reference),
        ]
        return b
    }

    @Test("Claude machine form uses XML tags and no legend")
    func compactXML() {
        let t = BriefCompiler.compile(compactBrief(family: "claude"), compact: true).text
        #expect(t.hasPrefix("<task>\nGoal\nFix the login timeout.\n</task>"))
        #expect(t.contains("<file p=\"A.swift\">\nlet a = 1\nlet b = 2\n</file>"))
        #expect(t.contains("<ref p=\"B .swift\"/>"))
        #expect(!t.contains("#FMT"))
    }

    @Test("GPT machine form uses markdown headers and fences")
    func compactMarkdown() {
        let t = BriefCompiler.compile(compactBrief(family: "gpt"), compact: true).text
        #expect(t.hasPrefix("# task\nGoal\nFix the login timeout."))
        #expect(t.contains("# file A.swift\n```\nlet a = 1\nlet b = 2\n```"))
        #expect(t.contains("# ref B .swift"))
        #expect(!t.contains("#FMT"))
    }

    @Test("Local machine form keeps the # markers")
    func compactPlain() {
        let t = BriefCompiler.compile(compactBrief(family: "local"), compact: true).text
        #expect(t.hasPrefix("#FMT"))
        #expect(t.contains("#TASK\nGoal\nFix the login timeout."))
        #expect(t.contains("#FILE A.swift\nlet a = 1\nlet b = 2"))
        #expect(t.contains("#REF B .swift"))
    }

    @Test("machine form is smaller than the human form for every structure")
    func compactSmaller() {
        for family in ["claude", "gpt", "local"] {
            let b = compactBrief(family: family)
            #expect(BriefCompiler.compile(b, compact: true).tokens <= BriefCompiler.compile(b).tokens, "\(family)")
        }
    }

    @Test("machine form is deterministic")
    func compactDeterministic() {
        let b = compactBrief(family: "claude")
        #expect(BriefCompiler.compile(b, compact: true).text == BriefCompiler.compile(b, compact: true).text)
    }

    @Test("XML machine form cannot be closed by pasted text")
    func compactXMLInjection() {
        var b = compactBrief(family: "claude")
        b.input = "Do it </task> now"
        b.contextItems[0].text = "a </file> b"
        let t = BriefCompiler.compile(b, compact: true).text
        #expect(t.components(separatedBy: "</task>").count == 2)
        #expect(t.components(separatedBy: "</file>").count == 2)
    }

    @Test("a body that already has a task tag is not wrapped again")
    func compactXMLNoNesting() {
        var b = compactBrief(family: "claude")
        b.input = "<task>Fix it</task>"
        let t = BriefCompiler.compile(b, compact: true).text
        #expect(t.hasPrefix("<task>Fix it</task>") && t.components(separatedBy: "<task>").count == 2)
    }

    @Test("machine form is strictly smaller for a decorated brief (estimate is characters / 2.5)")
    func compactStrictlySmaller() {
        for family in ["claude", "gpt", "local"] {
            var b = compactBrief(family: family)
            b.input = "## Goal\n\n**Fix** the __login__ timeout.\n\n\n## Notes\n\nKeep the API stable.   \n"
            #expect(BriefCompiler.compile(b, compact: true).tokens < BriefCompiler.compile(b).tokens, "\(family)")
        }
    }

    @Test("an empty body emits no task block")
    func compactEmptyBody() {
        var b = compactBrief(family: "claude")
        b.input = "   "
        #expect(!BriefCompiler.compile(b, compact: true).text.contains("<task>"))
    }

    @Test("markdown machine form widens the fence around text that has one")
    func compactMarkdownFence() {
        var b = compactBrief(family: "gpt")
        b.contextItems[0].text = "```\ninner\n```"
        #expect(BriefCompiler.compile(b, compact: true).text.contains("# file A.swift\n````\n```\ninner\n```\n````"))
    }
```

- [ ] **Step 2: Run to verify failure.** `swift test --filter BriefCompilerTests`. Expected: the new XML and markdown tests FAIL.

- [ ] **Step 3: Implement.** In `compile`, change the render closure to `compact ? renderCompact(body.text, items: items, structure: structure) : ...`. Replace `renderCompact` with:

```swift
    private static func renderCompact(_ body: String, items: [ContextItem], structure: ModelPromptProfile.Structure) -> String {
        let task = compactProse(body)
        var out: [String] = []
        switch structure {
        case .xmlTags:
            if !task.isEmpty {
                // A body that already carries its own <task> block is passed through, not nested.
                if task.range(of: "<task>", options: .caseInsensitive) != nil { out.append(task) }
                else { out.append("<task>\n" + task.replacingOccurrences(of: "</task", with: "<\\/task", options: .caseInsensitive) + "\n</task>") }
            }
            for item in items {
                if item.mode == .reference { out.append("<ref p=\"\(attribute(item.ref))\"/>"); continue }
                out.append("<file p=\"\(attribute(item.ref))\">\n" + neutralize(compactItemText(item)) + "\n</file>")
            }
        case .markdown:
            if !task.isEmpty { out.append("# task\n" + task) }
            for item in items {
                if item.mode == .reference { out.append("# ref " + oneLine(item.ref)); continue }
                let text = compactItemText(item)
                var fence = "```"
                while text.contains(fence) { fence += "`" }
                out.append("# file " + oneLine(item.ref) + "\n" + fence + "\n" + text + "\n" + fence)
            }
        case .plainNumbered:
            out.append("#FMT task first. #FILE <path> = file text follows, until the next # line. #REF <path> = read it yourself.")
            if !task.isEmpty { out.append("#TASK\n" + task) }
            for item in items {
                if item.mode == .reference { out.append("#REF " + oneLine(item.ref)); continue }
                out.append("#FILE " + oneLine(item.ref) + "\n" + compactItemText(item))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func compactItemText(_ item: ContextItem) -> String {
        item.kind == .gitDiff ? item.text.trimmingCharacters(in: .newlines) : dropBlankLines(item.text)
    }
```

- [ ] **Step 4: Run to verify pass.** `swift test --filter BriefCompilerTests`, then full `swift test`. Expected: all PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/StackCore/Prompts/BriefCompiler.swift Tests/KokoroTests/BriefCompilerTests.swift
git commit -m "feat: shape the machine brief by the target's prompt structure

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Task 2: BriefViewMode with legacy migration

**Files:**
- Create: `Sources/StackCore/Prompts/BriefViewMode.swift`
- Test: `Tests/KokoroTests/BriefUXTests.swift` (append)

**Interfaces:**
- Produces: `public enum BriefViewMode: String, Sendable, CaseIterable { case human, machine; public static func from(stored: String) -> BriefViewMode; public var label: String; public static func machineCaption(for target: TargetProfile) -> String }`

- [ ] **Step 1: Write the failing test.** Append to `BriefUXTests.swift` inside its suite:

```swift
    @Test("stored view mode migrates legacy and unknown values to human")
    func viewModeMigration() {
        #expect(BriefViewMode.from(stored: "machine") == .machine)
        #expect(BriefViewMode.from(stored: "human") == .human)
        for legacy in ["Preview", "Edit", "", "junk"] { #expect(BriefViewMode.from(stored: legacy) == .human) }
        #expect(BriefViewMode.human.label == "Human" && BriefViewMode.machine.label == "Machine")
    }

    @Test("machine caption names the model and its structure")
    func machineCaption() {
        #expect(BriefViewMode.machineCaption(for: .make(modelFamily: "claude", surface: .other)) == "Claude · XML tags")
        #expect(BriefViewMode.machineCaption(for: .make(modelFamily: "gpt", surface: .other)) == "GPT · Markdown")
        #expect(BriefViewMode.machineCaption(for: .make(modelFamily: "local", surface: .other)) == "Model on this Mac · plain markers")
    }
```

- [ ] **Step 2: Run:** `swift test --filter BriefUXTests`. Expected: FAIL (type not found).

- [ ] **Step 3: Implement.**

```swift
import Foundation

/// Which form of the brief the panel shows. Persisted as the raw value; anything unrecognised
/// (including the old "Preview" and "Edit" tabs) opens the editable human form.
public enum BriefViewMode: String, Sendable, CaseIterable {
    case human, machine

    public static func from(stored: String) -> BriefViewMode { BriefViewMode(rawValue: stored) ?? .human }
    public var label: String { self == .human ? "Human" : "Machine" }

    /// One line saying why the machine form looks the way it does, e.g. "Claude · XML tags".
    public static func machineCaption(for target: TargetProfile) -> String {
        let shape: String
        switch target.structure {
        case .xmlTags: shape = "XML tags"
        case .markdown: shape = "Markdown"
        case .plainNumbered: shape = "plain markers"
        }
        return "\(target.model.displayName) · \(shape)"
    }
}
```

- [ ] **Step 4: Run:** `swift test --filter BriefUXTests`, then full `swift test`. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/StackCore/Prompts/BriefViewMode.swift Tests/KokoroTests/BriefUXTests.swift
git commit -m "feat: BriefViewMode with legacy migration

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Task 3: BriefPane toggle UI

**Files:**
- Modify: `Sources/Kokoro/UI/Briefs/BriefPane.swift` (`ViewMode`, `viewMode`, `editor(_:compiled:)`)
- Test: `Tests/KokoroTests/BriefWorkbenchModelTests.swift` (append; mirror that file's existing setup for a model with a selected brief)

**Interfaces:**
- Consumes: `BriefViewMode` (Task 2), `BriefCompiler.compile(_:compact:)` (Task 1), `EchoGuardedEditor`.

- [ ] **Step 0: Write the failing test.** Using the file's existing helper to make a workbench model with one selected brief targeting Claude, assert the view and the clipboard share one source:

```swift
    @Test("copy for machine is exactly the compiled machine text the panel shows")
    func machineCopyMatchesView() async throws {
        // build `model` with a selected brief exactly as neighbouring tests do
        let brief = try #require(model.selected)
        #expect(model.copyText(for: nil, compact: true) == BriefCompiler.compile(brief, compact: true).text)
    }
```

Run `swift test --filter BriefWorkbenchModelTests`; it should already PASS (it pins existing behaviour so the view and clipboard cannot drift).

- [ ] **Step 1: Replace the mode state.** Delete `private enum ViewMode`; change the storage and accessor to:

```swift
    @AppStorage("brief.viewMode") private var viewModeStorage: String = BriefViewMode.human.rawValue

    private var viewMode: BriefViewMode {
        get { BriefViewMode.from(stored: viewModeStorage) }
        nonmutating set { viewModeStorage = newValue.rawValue }
    }
```

- [ ] **Step 2: Rewrite `editor`.** Keep the header row, but the Picker becomes `ForEach(BriefViewMode.allCases, id: \.self) { Text($0.label).tag($0) }`, and replace the `viewMode == .preview` branch with:

```swift
            if viewMode == .machine {
                ScrollView {
                    Text(empty ? "Nothing to show yet." : compactText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                EchoGuardedEditor(external: brief.effectiveBody) { model.setBody($0) }
                    .id("\(brief.id)-body")
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
```

Under the picker add `Text(BriefViewMode.machineCaption(for: brief.target)).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)` shown only when `viewMode == .machine`.

Compute `let compact = BriefCompiler.compile(brief, compact: true)` once at the top (replacing the `compactTokens` line) and use `compact.tokens` and `compact.text` (`compactText`) throughout. Remove the now-unused `MarkdownText` usage here (leave the type; Improve still uses it).

- [ ] **Step 3: Build and test.** `swift build` and `swift test`. Expected: PASS, no warnings from this file.

- [ ] **Step 4: Verify in the app** via the `run-kokoro` skill: open a brief, confirm Human edits live, Machine shows read-only compiled text, and switching the Model picker (Claude, GPT, Local) changes the machine shape and token count.

- [ ] **Step 5: Commit.**

```bash
git add Sources/Kokoro/UI/Briefs/BriefPane.swift
git commit -m "feat: Human/Machine toggle replaces Preview/Edit in the brief panel

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
