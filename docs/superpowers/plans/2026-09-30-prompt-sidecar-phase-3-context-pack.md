# Prompt Sidecar, Phase 3 (Context Pack) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Brief carry repo context: search the index, add files, add the working git diff; see per-item token cost and provenance; include, exclude, inline or reference each item; and guarantee secrets never reach a compiled prompt.

**Architecture:** Three pure pieces in `StackCore/Prompts` (`ContextRedactor`, `ContextItemFactory`, compiler integration) plus a small I/O layer (`GitDiffReader`) and a `BriefContextSource` closure bundle wired in `AppServices`. `BriefWorkbenchModel` gains item operations. The UI adds a context list under the Context section and a picker sheet. The compiler stays deterministic and makes no model calls.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Swift Testing, existing `IndexingPipeline.search`, `WorkspaceManager`.

**Spec:** `docs/superpowers/specs/2026-09-29-prompt-sidecar-design.md` (§3.1 `ContextItem`, §4 Context Pack, phase 3 of §5, §6 redaction test).

## Global Constraints

- Local-only mode makes zero outbound requests: nothing here touches the network.
- Seeded secrets never appear in a compiled prompt (spec §6).
- `ContextItem` JSON must keep decoding old brief files: no new required fields.
- Nothing is dropped silently: every redaction, downgrade or drop is a `BriefWarning`.
- Files are read only from inside a registered workspace root (symlinks resolved).
- Stage only your own files; never `git add -A`.

## Ruling made while planning

- The spec's separate "Context" sidebar item is **not** added: context belongs to a brief, so it lives in the brief's Context section. Cost if wrong: one more nav case later.
- Workspace roots come from `WorkspaceManager.list`, not `detectWorkspaceURL()` (which walks up from the process's cwd and finds nothing in a launched `.app`).

## Review Focus

- File that is binary, huge (over 200 KB) or unreadable: rejected with a plain reason, never half-added.
- Path outside every workspace root, or a symlink pointing out of it: rejected.
- Secret split across the `</file>` escaping or inside a diff line: still redacted.
- Two adds of the same file: one item (updated), not duplicates.
- No workspace registered, or no git repo: the picker says so in one sentence; the brief is unchanged.
- Search returns a chunk twice (same file and text): one item.

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/StackCore/Prompts/ContextRedactor.swift` | Pure secret/PII scan and redact |
| Modify `Sources/StackCore/Prompts/BriefCompiler.swift` | Redact all emitted text; `.secretRedacted` warning |
| Create `Sources/StackCore/Prompts/ContextItemFactory.swift` | Files, search hits, diffs to `ContextItem` |
| Create `Sources/StackCore/Git/GitDiffReader.swift` | Working-tree diff via `git` |
| Modify `Sources/VibeCockpit/App/BriefWorkbenchModel.swift` | add/remove/toggle/mode for items |
| Create `Sources/VibeCockpit/App/BriefContextSource.swift` | Search, roots, diff closures |
| Modify `Sources/VibeCockpit/App/AppServices.swift` | Build the source from the pipeline and `WorkspaceManager` |
| Create `Sources/VibeCockpit/UI/Briefs/ContextListView.swift`, `ContextPickerSheet.swift` | UI |
| Modify `Sources/VibeCockpit/UI/Briefs/BriefWorkbenchView.swift` | Show the list under Context |
| Create `Tests/VibeCockpitTests/ContextRedactorTests.swift`, `ContextItemFactoryTests.swift`, `GitDiffReaderTests.swift`; modify `BriefCompilerTests.swift`, `BriefWorkbenchModelTests.swift` | Tests |

---

### Task 1: ContextRedactor and compiler integration

**Files:** create `ContextRedactor.swift`, `ContextRedactorTests.swift`; modify `BriefCompiler.swift`, `BriefCompilerTests.swift`.

**Interfaces:**
- Produces: `struct ContextRedactor.Finding { kind: String; range: Range<String.Index> }`; `ContextRedactor.scan(_:) -> [Finding]`; `ContextRedactor.redact(_:) -> (text: String, count: Int)` replacing each secret with `[redacted \(kind)]`; new `BriefWarning.Code.secretRedacted`.

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import StackCore

@Suite("ContextRedactor")
struct ContextRedactorTests {
    @Test("known secret shapes are redacted", arguments: [
        ("AWS", "key = AKIAIOSFODNN7EXAMPLE"),
        ("GitHub token", "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
        ("API key", "OPENAI_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"),
        ("private key", "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----"),
        ("bearer token", "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdefghij.klmnopqrst"),
        ("password", #"password = "hunter2hunter2""#),
    ])
    func redacts(kind: String, sample: String) {
        let out = ContextRedactor.redact(sample)
        #expect(out.count == 1)
        #expect(out.text.contains("[redacted"))
        #expect(!out.text.contains("AKIAIOSFODNN7EXAMPLE") && !out.text.contains("ghp_abc")
                && !out.text.contains("sk-abc") && !out.text.contains("MIIEow")
                && !out.text.contains("eyJhbGci") && !out.text.contains("hunter2"))
    }

    @Test("ordinary code is untouched")
    func untouched() {
        let code = "let key = cache.key(for: user)\nfunc tokenize(_ s: String) -> [Token] { [] }\nlet password = prompt()"
        let out = ContextRedactor.redact(code)
        #expect(out.text == code)
        #expect(out.count == 0)
    }

    @Test("redaction is idempotent")
    func idempotent() {
        let once = ContextRedactor.redact("k=AKIAIOSFODNN7EXAMPLE").text
        #expect(ContextRedactor.redact(once).text == once)
    }
}
```

Compiler test (append to `BriefCompilerTests.swift`, matching its existing helper style — read the file first and reuse its brief-building helper):

```swift
@Test("seeded secrets never reach the compiled prompt, and a warning says so")
func secretsNeverCompiled() {
    var brief = Brief.new(title: "t", target: .make(modelFamily: "claude", surface: .chatGPTWeb))
    brief.setText("Fix the deploy. My key is sk-abcdefghijklmnopqrstuvwxyz123456", for: .goal)
    brief.contextItems = [ContextItem(kind: .file, ref: "env.swift", text: "let k = \"AKIAIOSFODNN7EXAMPLE\"", mode: .inline)]
    let out = BriefCompiler.compile(brief)
    #expect(!out.text.contains("sk-abcdef") && !out.text.contains("AKIAIOSFODNN7EXAMPLE"))
    #expect(out.warnings.contains { $0.code == .secretRedacted })
}
```

- [ ] **Step 2:** `swift test --filter ContextRedactor` → FAIL (`ContextRedactor` missing).
- [ ] **Step 3: Implement.** `ContextRedactor` holds an ordered list of `(kind, NSRegularExpression)`: AWS `AKIA[0-9A-Z]{16}`; GitHub `gh[pousr]_[A-Za-z0-9]{30,}`; `sk-[A-Za-z0-9_-]{20,}`; PEM `-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`; `Bearer\s+[A-Za-z0-9._-]{20,}`; assignment `(?i)(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*["'][^"'\s]{8,}["']`. `redact` applies them in order from the end of the string backwards so ranges stay valid, replacing the secret part only. Placeholder text `[redacted kind]` must not match any pattern (idempotence). In `BriefCompiler.compile`, run `redact` over every enabled section text and every included item text before rendering, sum the counts, and append one `.secretRedacted` warning ("N secret(s) were removed from the prompt.") when the sum is above zero. Add `secretRedacted` to `BriefWarning.Code`.
- [ ] **Step 4:** `swift test --filter "ContextRedactor|BriefCompiler"` → PASS.
- [ ] **Step 5: Commit** `feat(briefs): redact secrets from every compiled prompt`.

---

### Task 2: ContextItemFactory

**Files:** create `ContextItemFactory.swift`, `ContextItemFactoryTests.swift`.

**Interfaces:**
- Consumes: `ContextItem.init`, `Surface.defaultContextMode`, `PromptTokens.estimate`.
- Produces:
  - `enum ContextItemError: LocalizedError, Equatable { case outsideWorkspace, unreadable, binary, tooLarge(Int) }`
  - `ContextItemFactory.file(at: URL, roots: [URL], surface: Surface, provenance: String) throws -> ContextItem` (ref = path relative to its root; id = stable hash of the absolute path so re-adding updates)
  - `ContextItemFactory.hit(filePath: String, kind: String, content: String, query: String, roots: [URL], surface: Surface) -> ContextItem` (kind `.symbol`, ref `relative/path — kind`, id = hash of path+content)
  - `ContextItemFactory.diff(_ text: String, ref: String) -> ContextItem` (kind `.gitDiff`, mode `.inline`, priority above files)
  - `static let maxFileBytes = 200_000`

- [ ] **Step 1: Failing tests** (use a temp directory helper that creates `root/a.swift`, `root/big.bin`, `root/link -> /etc/hosts`):

```swift
import Testing
import Foundation
@testable import StackCore

@Suite("ContextItemFactory")
struct ContextItemFactoryTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    @Test("a file becomes an item with a relative ref and the surface's default mode")
    func file() throws {
        let root = try makeRoot()
        try "func a() {}".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let item = try ContextItemFactory.file(at: root.appendingPathComponent("a.swift"), roots: [root],
                                               surface: .claudeCode, provenance: "picked")
        #expect(item.ref == "a.swift")
        #expect(item.mode == .reference)
        #expect(item.tokens > 0 && item.text == "func a() {}")
        let again = try ContextItemFactory.file(at: root.appendingPathComponent("a.swift"), roots: [root],
                                                surface: .chatGPTWeb, provenance: "picked")
        #expect(again.id == item.id && again.mode == .inline)
    }

    @Test("paths outside every root are rejected, including through a symlink")
    func outside() throws {
        let root = try makeRoot()
        let other = try makeRoot()
        try "x".write(to: other.appendingPathComponent("o.txt"), atomically: true, encoding: .utf8)
        #expect(throws: ContextItemError.outsideWorkspace) {
            try ContextItemFactory.file(at: other.appendingPathComponent("o.txt"), roots: [root], surface: .other, provenance: "")
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                                   withDestinationURL: other.appendingPathComponent("o.txt"))
        #expect(throws: ContextItemError.outsideWorkspace) {
            try ContextItemFactory.file(at: root.appendingPathComponent("link.txt"), roots: [root], surface: .other, provenance: "")
        }
    }

    @Test("binary and oversized files are rejected with a reason")
    func rejects() throws {
        let root = try makeRoot()
        try Data([0, 1, 2, 0, 255]).write(to: root.appendingPathComponent("b.bin"))
        try String(repeating: "a", count: ContextItemFactory.maxFileBytes + 1)
            .write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        #expect(throws: ContextItemError.binary) {
            try ContextItemFactory.file(at: root.appendingPathComponent("b.bin"), roots: [root], surface: .other, provenance: "")
        }
        #expect(throws: (any Error).self) {
            try ContextItemFactory.file(at: root.appendingPathComponent("big.txt"), roots: [root], surface: .other, provenance: "")
        }
        #expect(throws: ContextItemError.unreadable) {
            try ContextItemFactory.file(at: root.appendingPathComponent("missing.txt"), roots: [root], surface: .other, provenance: "")
        }
    }

    @Test("the same search hit gets the same id, and carries its query as provenance")
    func hit() {
        let root = URL(fileURLWithPath: "/w")
        let a = ContextItemFactory.hit(filePath: "/w/S.swift", kind: "func", content: "func f() {}", query: "login", roots: [root], surface: .cursor)
        let b = ContextItemFactory.hit(filePath: "/w/S.swift", kind: "func", content: "func f() {}", query: "login", roots: [root], surface: .cursor)
        #expect(a.id == b.id && a.kind == .symbol)
        #expect(a.provenance == "search: login")
        #expect(a.ref.hasPrefix("S.swift"))
    }

    @Test("a diff is inline and outranks files")
    func diff() {
        let d = ContextItemFactory.diff("+new line", ref: "working changes")
        #expect(d.kind == .gitDiff && d.mode == .inline && d.priority > 0)
    }
}
```

- [ ] **Step 2:** run → FAIL. **Step 3: Implement**: resolve `url.resolvingSymlinksInPath()` and require `path.hasPrefix(root.path + "/")` for some resolved root; read `Data`, reject `> maxFileBytes` with `.tooLarge`, reject if it contains a NUL byte (`.binary`) or is not valid UTF-8 (`.binary`); id via SHA-256 of the string (`CryptoKit`) hex-prefix 16; provenance for hit is `"search: \(query)"`. **Step 4:** run → PASS. **Step 5: Commit** `feat(briefs): build context items from files, search hits and diffs`.

---

### Task 3: GitDiffReader

**Files:** create `Sources/StackCore/Git/GitDiffReader.swift`, `Tests/VibeCockpitTests/GitDiffReaderTests.swift`.

**Interfaces:**
- Produces: `enum GitDiffError: LocalizedError, Equatable { case notARepository, gitUnavailable, failed(String) }`; `GitDiffReader.workingDiff(in root: URL, maxBytes: Int = 200_000) async throws -> String` (runs `/usr/bin/git -C root diff HEAD --no-color`; empty string means no changes; output longer than `maxBytes` is cut on a line boundary with a final line `… (diff cut to fit)`).

- [ ] **Step 1: Failing tests** — create a temp dir, `git init`, set `user.email`/`user.name` via `-c`, commit `a.txt`, modify it, and assert: the diff contains `+changed`; a clean tree returns `""`; a non-repo directory throws `.notARepository`; a 300 KB change returns text under the cap ending with the cut marker. Use `Process` in the test helper only for setup.
- [ ] **Step 2:** run → FAIL. **Step 3: Implement** with `Process`, `Pipe`, reading stdout with `readToEnd()` off the main thread inside `withCheckedThrowingContinuation` on a detached task; map exit code 128 with "not a git repository" to `.notARepository`; missing executable to `.gitUnavailable`. **Step 4:** PASS. **Step 5: Commit** `feat(briefs): read the working git diff`.

---

### Task 4: Model operations and context source

**Files:** modify `BriefWorkbenchModel.swift`, `BriefWorkbenchModelTests.swift`; create `BriefContextSource.swift`; modify `AppServices.swift`.

**Interfaces:**
- Consumes: Task 2 factory, Task 3 reader, `IndexingPipeline.search(query:topK:) -> [SearchResult]`, `WorkspaceManager.list`.
- Produces:
  - `BriefWorkbenchModel.addContext(_ items: [ContextItem])` (replaces an item with the same id, keeps its `included`), `removeContext(id:)`, `setContextIncluded(_:id:)`, `setContextMode(_:id:)`
  - `BriefWorkbenchModel.contextTokens: Int` (sum over included items)
  - `struct BriefContextSource: Sendable { var roots: @Sendable () async -> [URL]; var search: @Sendable (String) async -> [SearchResult]; var workingDiff: @Sendable (URL) async throws -> String }` and `BriefWorkbenchModel.contextSource: BriefContextSource?` (set by `AppServices`)
  - `func searchContext(_ query: String) async -> [ContextItem]`, `func addFile(_ url: URL) async throws`, `func addWorkingDiff() async throws` on the model, each using the selected brief's surface.

- [ ] **Step 1: Failing tests** in `BriefWorkbenchModelTests`:

```swift
@Test("adding an item twice keeps one item and its include state")
func addTwice() async {
    let (m, _) = make()
    await m.newBrief(title: "t")
    let item = ContextItem(id: "x", kind: .file, ref: "a.swift", text: "func a() {}", mode: .inline)
    m.addContext([item]); m.setContextIncluded(false, id: "x")
    m.addContext([item])
    #expect(m.selected?.contextItems.count == 1)
    #expect(m.selected?.contextItems.first?.included == false)
}

@Test("excluded items cost nothing and reference mode changes the compiled text")
func toggles() async {
    let (m, _) = make()
    await m.newBrief(title: "t"); m.setText("Do X", for: .goal)
    m.addContext([ContextItem(id: "x", kind: .file, ref: "a.swift", text: "func a() {}", mode: .inline)])
    #expect(m.contextTokens > 0)
    m.setContextMode(.reference, id: "x")
    #expect(m.compiled?.text.contains("func a() {}") == false)
    m.setContextIncluded(false, id: "x")
    #expect(m.contextTokens == 0)
    m.removeContext(id: "x")
    #expect(m.selected?.contextItems.isEmpty == true)
}

@Test("search results become items with the brief's surface mode; no source means no items")
func search() async {
    let (m, _) = make()
    await m.newBrief(title: "t")
    #expect(await m.searchContext("login").isEmpty)
    m.contextSource = BriefContextSource(
        roots: { [URL(fileURLWithPath: "/w")] },
        search: { _ in [SearchResult(chunkID: UUID(), filePath: "/w/S.swift", declarationKind: "func", content: "func f() {}", score: 1, rank: 1)] },
        workingDiff: { _ in "" })
    let items = await m.searchContext("login")
    #expect(items.count == 1 && items[0].mode == .reference)
}

@Test("an empty working diff is reported, not added")
func emptyDiff() async {
    let (m, _) = make()
    await m.newBrief(title: "t")
    m.contextSource = BriefContextSource(roots: { [URL(fileURLWithPath: "/w")] }, search: { _ in [] }, workingDiff: { _ in "" })
    await #expect(throws: ContextItemError.self) { try await m.addWorkingDiff() }
    #expect(m.selected?.contextItems.isEmpty == true)
}
```

(Add `case noChanges` and `case noWorkspace` to `ContextItemError` for the last two; check `SearchResult.init` labels in `VectorStore.swift:19` and fix the test call to match.)

- [ ] **Step 2:** run → FAIL. **Step 3: Implement** the operations with `mutate`; `contextTokens` sums `tokens` of included items; `searchContext` dedupes by id and returns `[]` without a source; `addFile` / `addWorkingDiff` use `contextSource.roots().first` (throw `.noWorkspace` if none). In `AppServices.init`/`startup`, set `briefs.contextSource = BriefContextSource(roots: { await workspaces.list.map(\.record.url) }, search: { [weak self] q in (try? await self?.indexingPipeline?.search(query: q, topK: 8)) ?? [] }, workingDiff: { try await GitDiffReader.workingDiff(in: $0) })`. **Step 4:** run model tests → PASS, then full `swift test --parallel`. **Step 5: Commit** `feat(briefs): context operations and workspace source`.

---

### Task 5: Context UI

**Files:** create `ContextListView.swift`, `ContextPickerSheet.swift`; modify `BriefWorkbenchView.swift`.

**Interfaces:** consumes the Task 4 model API.

- [ ] **Step 1: `ContextListView`** — shown inside the Context section, below its text editor. One row per item: include toggle, `ref`, kind icon, `~N tokens`, a segmented Inline/Reference control, provenance in secondary text, remove button. A footer line "N items, about M tokens" and an "Add context…" button opening the picker. Rows for items the compiler warned about (`compiled.warnings` with matching `itemID`) show the warning text in secondary style.
- [ ] **Step 2: `ContextPickerSheet`** — three tabs. *Search*: text field, Return runs `model.searchContext`, results list with token cost and an Add button each (Add-all button too). *File*: "Choose file…" runs `NSOpenPanel` rooted at the first workspace, then `addFile`. *Changes*: "Add working changes" runs `addWorkingDiff`. Every failure shows `error.localizedDescription` in one line under the tab; nothing is added on failure. If `roots()` is empty the sheet shows "Add a project in Settings first." and disables the tabs.
- [ ] **Step 3:** Wire into `BriefWorkbenchView.sectionEditor` (only when `kind == .context`).
- [ ] **Step 4: Verify.** `Scripts/dev-run.sh`, then on screen: add a file, see its tokens and the compiled pane update; flip Inline/Reference and watch the pane change; exclude it and watch the meter drop; try the Changes tab in a clean repo and confirm the one-line message; search with no index shows an empty result, not an error.
- [ ] **Step 5: Commit** `feat(briefs): context list and picker`; update `CLAUD.md` status to "phases 0-3 shipped".

## Self-review

- **Spec coverage (phase 3):** RAG picker (Task 4/5), git diff (3), per-item token cost, include/exclude, provenance (2, 5), secrets scan (1), budget behavior already in the compiler. PII beyond secrets (emails, names) is **not** covered: only credentials are; noted as a gap to decide.
- **Types:** `ContextItemError` is defined in Task 2 and extended in Task 4; `BriefContextSource` fields match between Tasks 4 and 5.
