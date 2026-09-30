# Prompt Sidecar, Phase 2 (Brief Workbench UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chat as the app's center with a Brief workbench: pick or create a Brief, edit its sections, see the compiled prompt, choose a target, and copy it.

**Architecture:** A `@MainActor @Observable BriefWorkbenchModel` wraps the existing `BriefStore` and `BriefCompiler` (both pure and tested in phase 1). The center column becomes a section editor; the detail (right) column becomes the compiled-prompt pane. The chat moves behind a "Quick ask" sidebar item and is otherwise untouched. No inference changes in this phase except reusing the existing "Improve" sheet on the Goal section.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI (macOS 26), Swift Testing, XcodeGen (`Scripts/dev-run.sh` regenerates and rebuilds).

**Spec:** `docs/superpowers/specs/2026-09-29-prompt-sidecar-design.md` (§3.4 UI, §3.5 copy variants, phase 2 of §5).

## Scope note

The spec's phases 3–6 (Context Pack, interview and critique, handoff and versions UI, loop) each depend on the interfaces this phase creates (`BriefWorkbenchModel`, the compiled pane). They get their own plans once this one ships; writing them now would guess at those interfaces. Phase 2's "remove hidden augmentation" item (`PromptEngineer.augmentUserTurn`) is **not** in this plan: the chat still uses it, and the spec's point of no return is "not before phase 4".

## Global Constraints

- Display name **Kokoro**, subtitle **Prompt sidecar**; voice only in short notes and empty states.
- Navigation from the spec: **Briefs, Library, Context, Models, Settings**. Context is phase 3, so it is not shown yet.
- Nothing is deleted: chat, diff, snapshots and MCP tools stay defined; IDE panes stay hidden.
- Swift 6 strict concurrency; UI models are `@MainActor @Observable`.
- Model output is never written into a Brief unprompted; it goes through a review the user accepts.
- Tests: `swift test --filter <Suite>`. Views compile only under Xcode: verify with `Scripts/dev-run.sh`.
- Stage only your own files; never `git add -A`.

## Review Focus

- No Briefs exist yet: the center shows an empty state with one "New brief" action, not a blank pane.
- Deleting the selected Brief selects a neighbor or falls back to the empty state.
- Editing text quickly then quitting: the last edit is saved (flush on disappear), not lost to a debounce.
- Brief with a disabled or empty Goal: the compiled pane shows the compiler's warning, and Copy stays enabled only when the compiled text is non-empty.
- Switching target surface on an over-budget Brief updates warnings without touching the section text.

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/VibeCockpit/App/BriefWorkbenchModel.swift` | Brief list, selection, edits, autosave, compile, copy text |
| Create `Sources/VibeCockpit/UI/Briefs/BriefWorkbenchView.swift` | Center: brief picker, section editors, Improve on Goal |
| Create `Sources/VibeCockpit/UI/Briefs/CompiledPromptPane.swift` | Right: target picker, meter, warnings, Copy |
| Modify `Sources/VibeCockpit/App/NavDestination.swift` | Add `.briefs`; reorder and relabel |
| Modify `Sources/VibeCockpit/UI/ContentView.swift` | Route `.briefs` to the new views; default destination |
| Modify `Sources/VibeCockpit/App/AppServices.swift` | Own a `BriefWorkbenchModel` |
| Create `Tests/VibeCockpitTests/BriefWorkbenchModelTests.swift` | Model tests |
| Modify `Tests/VibeCockpitTests/NavigationTests.swift` | Pin new nav |

---

### Task 1: BriefWorkbenchModel

**Files:**
- Create: `Sources/VibeCockpit/App/BriefWorkbenchModel.swift`
- Test: `Tests/VibeCockpitTests/BriefWorkbenchModelTests.swift`

**Interfaces:**
- Consumes: `BriefStore` (`all() -> [Brief]`, `save(_:) throws`, `delete(id:) throws`), `Brief.new(title:target:workspace:)`, `Brief.setText(_:for:)`, `Brief.snapshot()`, `BriefCompiler.compile(_:) -> CompiledPrompt`, `TargetProfile.make(modelFamily:surface:)`.
- Produces:
  - `BriefWorkbenchModel(store: BriefStore)`
  - `var briefs: [Brief]`, `var selectedID: String?`, `var selected: Brief?`, `var compiled: CompiledPrompt?`, `var saveError: String?`
  - `func reload() async`, `func newBrief(title: String) async`, `func select(_ id: String?)`, `func setText(_ text: String, for kind: BriefSection.Kind)`, `func setEnabled(_ on: Bool, for kind: BriefSection.Kind)`, `func setTarget(modelFamily: String, surface: Surface)`, `func deleteSelected() async`, `func copyText(for surface: Surface?) -> String`, `func flush() async`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@MainActor
@Suite("BriefWorkbenchModel")
struct BriefWorkbenchModelTests {
    private func make() -> (BriefWorkbenchModel, BriefStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        return (BriefWorkbenchModel(store: store), store)
    }

    @Test("new brief is selected, compiled and persisted")
    func newBrief() async throws {
        let (m, store) = make()
        await m.newBrief(title: "Fix login")
        #expect(m.briefs.count == 1)
        #expect(m.selected?.title == "Fix login")
        #expect(m.compiled != nil)
        await m.flush()
        #expect(await store.all().count == 1)
    }

    @Test("editing the goal recompiles and saves")
    func editGoal() async {
        let (m, store) = make()
        await m.newBrief(title: "t")
        m.setText("Add a retry to the upload call", for: .goal)
        #expect(m.compiled?.text.contains("Add a retry") == true)
        await m.flush()
        #expect(await store.all().first?.text(of: .goal) == "Add a retry to the upload call")
    }

    @Test("empty goal warns and copy text is empty")
    func emptyGoal() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        #expect(m.compiled?.warnings.contains { $0.code == .emptyGoal } == true)
        #expect(m.copyText(for: nil).isEmpty)
    }

    @Test("changing surface keeps section text and recompiles")
    func surface() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setText("Do X", for: .goal)
        m.setTarget(modelFamily: "claude", surface: .chatGPTWeb)
        #expect(m.selected?.target.surface == .chatGPTWeb)
        #expect(m.selected?.text(of: .goal) == "Do X")
    }

    @Test("copy for a surface does not change the brief's own target")
    func copyVariant() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setText("Do X", for: .goal)
        let before = m.selected?.target
        _ = m.copyText(for: .claudeCode)
        #expect(m.selected?.target == before)
    }

    @Test("deleting the selected brief selects a neighbor, then nothing")
    func delete() async {
        let (m, _) = make()
        await m.newBrief(title: "a")
        await m.newBrief(title: "b")
        await m.deleteSelected()
        #expect(m.briefs.count == 1)
        #expect(m.selected != nil)
        await m.deleteSelected()
        #expect(m.briefs.isEmpty)
        #expect(m.selected == nil)
        #expect(m.compiled == nil)
    }

    @Test("a corrupt file in the store does not stop the others loading")
    func corrupt() async throws {
        let (m, store) = make()
        await m.newBrief(title: "ok")
        await m.flush()
        try "{nope".write(to: store.directory.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        let m2 = BriefWorkbenchModel(store: BriefStore(directory: store.directory))
        await m2.reload()
        #expect(m2.briefs.count == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BriefWorkbenchModel`
Expected: FAIL, `cannot find 'BriefWorkbenchModel' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// The Brief workbench's state: the list, the selected brief, and its compiled prompt.
/// Views read this and call it; compile is pure so it runs on every edit.
@MainActor
@Observable
public final class BriefWorkbenchModel {
    public private(set) var briefs: [Brief] = []
    public private(set) var selectedID: String?
    public private(set) var compiled: CompiledPrompt?
    public private(set) var saveError: String?

    private let store: BriefStore
    private var pendingSave: Task<Void, Never>?

    public init(store: BriefStore) { self.store = store }

    public var selected: Brief? { briefs.first { $0.id == selectedID } }

    public func reload() async {
        briefs = await store.all()
        if selected == nil { selectedID = briefs.first?.id }
        recompile()
    }

    public func newBrief(title: String) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = Brief.new(title: name.isEmpty ? "Untitled brief" : name,
                              target: .make(modelFamily: "claude", surface: .claudeCode))
        briefs.insert(brief, at: 0)
        selectedID = brief.id
        recompile()
        await persist(brief)
    }

    public func select(_ id: String?) { selectedID = id; recompile() }

    public func setText(_ text: String, for kind: BriefSection.Kind) {
        mutate { $0.setText(text, for: kind) }
    }

    public func setEnabled(_ on: Bool, for kind: BriefSection.Kind) {
        mutate { brief in
            if let i = brief.sections.firstIndex(where: { $0.kind == kind }) { brief.sections[i].enabled = on }
            brief.updatedAt = Date()
        }
    }

    public func setTarget(modelFamily: String, surface: Surface) {
        mutate { $0.target = .make(modelFamily: modelFamily, surface: surface); $0.updatedAt = Date() }
    }

    public func deleteSelected() async {
        guard let id = selectedID, let index = briefs.firstIndex(where: { $0.id == id }) else { return }
        briefs.remove(at: index)
        selectedID = briefs.isEmpty ? nil : briefs[min(index, briefs.count - 1)].id
        recompile()
        do { try await store.delete(id: id) } catch { saveError = error.localizedDescription }
    }

    /// The text to paste. `surface` restyles for a different tool without changing the brief.
    public func copyText(for surface: Surface?) -> String {
        guard var brief = selected else { return "" }
        if let surface, surface != brief.target.surface {
            brief.target = TargetProfile(modelFamily: brief.target.modelFamily, surface: surface,
                                         tokenBudget: brief.target.tokenBudget)
            for i in brief.contextItems.indices { brief.contextItems[i].mode = surface.defaultContextMode }
        }
        let out = BriefCompiler.compile(brief)
        return out.warnings.contains { $0.code == .emptyGoal } ? "" : out.text
    }

    /// Waits for the last edit to reach disk. Call before the view goes away.
    public func flush() async { await pendingSave?.value }

    private func mutate(_ change: (inout Brief) -> Void) {
        guard let i = briefs.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&briefs[i])
        recompile()
        let brief = briefs[i]
        pendingSave?.cancel()
        let previous = pendingSave
        pendingSave = Task { [store] in
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do { try await store.save(brief) } catch { await MainActor.run { self.saveError = error.localizedDescription } }
        }
    }

    private func persist(_ brief: Brief) async {
        do { try await store.save(brief) } catch { saveError = error.localizedDescription }
    }

    private func recompile() { compiled = selected.map(BriefCompiler.compile) }
}
```

Note on `flush()`: a cancelled task returns immediately, so `flush` must await the newest task; `mutate` above always replaces `pendingSave` with the newest one, and the newest awaits its predecessor, so `flush` waits for the final write. If the 300 ms wait makes the tests slow, lower it via an `init(saveDelay: Duration = .milliseconds(300))` parameter and pass `.zero` in `make()`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BriefWorkbenchModel`
Expected: 7 tests PASS. If `flush` returns before the write (edit test fails), fix the task chaining, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeCockpit/App/BriefWorkbenchModel.swift Tests/VibeCockpitTests/BriefWorkbenchModelTests.swift
git commit -m "feat(briefs): workbench model with autosave and live compile"
```

---

### Task 2: Navigation and AppServices wiring

**Files:**
- Modify: `Sources/VibeCockpit/App/NavDestination.swift`
- Modify: `Sources/VibeCockpit/App/AppServices.swift` (near `promptStudio`, line ~60 and ~97; and the async setup near line ~151)
- Test: `Tests/VibeCockpitTests/NavigationTests.swift`

**Interfaces:**
- Consumes: `BriefWorkbenchModel(store:)`, `BriefStore()`.
- Produces: `NavDestination.briefs`; `AppServices.briefs: BriefWorkbenchModel`; `NavDestination.sidebarPrimary == [.briefs, .prompts, .models]`, `sidebarSecondary == [.chat, .tools, .settings]`.

- [ ] **Step 1: Update the failing test.** Open `Tests/VibeCockpitTests/NavigationTests.swift`, read what it currently pins, and change it to:

```swift
@Test("sidebar offers Briefs, Library, Models, then Quick ask, MCP Tools, Settings")
func sidebar() {
    #expect(NavDestination.sidebarPrimary == [.briefs, .prompts, .models])
    #expect(NavDestination.sidebarSecondary == [.chat, .tools, .settings])
    #expect(NavDestination.briefs.label == "Briefs")
    #expect(NavDestination.prompts.label == "Library")
    #expect(NavDestination.chat.label == "Quick ask")
    #expect(!NavDestination.sidebarPrimary.contains(.diff))
    #expect(!NavDestination.sidebarPrimary.contains(.snapshots))
}
```

- [ ] **Step 2: Run** `swift test --filter Navigation`. Expected: FAIL (`.briefs` missing).

- [ ] **Step 3: Implement.** In `NavDestination.swift` add `case briefs`; set `sidebarPrimary = [.briefs, .prompts, .models]`, `sidebarSecondary = [.chat, .tools, .settings]`; labels `.briefs: "Briefs"`, `.prompts: "Library"`, `.chat: "Quick ask"`; icon `.briefs: "doc.text.fill"`. In `AppServices.swift` add `public let briefs: BriefWorkbenchModel`, initialize it with `BriefWorkbenchModel(store: BriefStore())` in `init` next to `promptStudio`, and `await briefs.reload()` next to `await promptStudio.reload()`.

- [ ] **Step 4: Run** `swift test --filter Navigation`. Expected: PASS. The build will fail in `ContentView.swift` on the non-exhaustive `switch`; that is fixed in Task 3.

- [ ] **Step 5: Commit** (after Task 3 compiles, to keep every commit buildable — commit Tasks 2 and 3 together).

---

### Task 3: Workbench views

**Files:**
- Create: `Sources/VibeCockpit/UI/Briefs/BriefWorkbenchView.swift`
- Create: `Sources/VibeCockpit/UI/Briefs/CompiledPromptPane.swift`
- Modify: `Sources/VibeCockpit/UI/ContentView.swift` (`selectedDestination` default at line ~36, `contentPanel` ~183, `detailPanel` ~198, `badge(for:)` ~85)

**Interfaces:**
- Consumes: `AppServices.briefs`, `BriefWorkbenchModel` API from Task 1, `MTDivider`, `MTFilledButtonStyle`, `Color.mt*`, `Font.mt*`.
- Produces: `BriefWorkbenchView()` (center), `CompiledPromptPane()` (right).

- [ ] **Step 1: Write `BriefWorkbenchView.swift`.**

```swift
#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Center column: pick a brief, edit its sections. The compiled prompt is on the right.
struct BriefWorkbenchView: View {
    @Environment(AppServices.self) private var services
    @State private var newTitle = ""
    @State private var creating = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(spacing: 0) {
            header
            MTDivider()
            if let brief = model.selected {
                editor(brief)
            } else {
                emptyState
            }
        }
        .background(Color.mtSurface)
        .task { await model.reload() }
        .onDisappear { Task { await model.flush() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Brief", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.briefs) { Text($0.title).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .disabled(model.briefs.isEmpty)
            Spacer()
            Button { creating = true } label: { Label("New brief", systemImage: "plus") }
                .buttonStyle(MTFilledButtonStyle())
            Button(role: .destructive) { Task { await model.deleteSelected() } } label: { Image(systemName: "trash") }
                .disabled(model.selected == nil)
                .help("Delete this brief")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .alert("New brief", isPresented: $creating) {
            TextField("What is it for?", text: $newTitle)
            Button("Create") { let t = newTitle; newTitle = ""; Task { await model.newBrief(title: t) } }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
            Text("No briefs yet").font(.mtTitleMedium)
            Text("A brief is the prompt you will hand to Claude Code, Cursor or ChatGPT. Start one and shape it here.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            Button("New brief") { creating = true }.buttonStyle(MTFilledButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editor(_ brief: Brief) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(BriefSection.Kind.allCases, id: \.self) { kind in
                    sectionEditor(kind, section: brief.sections.first { $0.kind == kind })
                }
            }
            .padding(16)
        }
    }

    private func sectionEditor(_ kind: BriefSection.Kind, section: BriefSection?) -> some View {
        let enabled = section?.enabled ?? true
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.title(kind)).font(.mtLabelLarge)
                Text("~\(PromptTokens.estimate(section?.text ?? "")) tokens")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Spacer()
                Toggle("Include", isOn: Binding(get: { enabled }, set: { model.setEnabled($0, for: kind) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            TextEditor(text: Binding(get: { section?.text ?? "" }, set: { model.setText($0, for: kind) }))
                .font(.mtBodyMedium)
                .frame(minHeight: kind == .goal ? 110 : 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .opacity(enabled ? 1 : 0.5)
            Text(Self.hint(kind)).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    static func title(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "Goal"
        case .context: "Context"
        case .constraints: "Constraints"
        case .examples: "Examples"
        case .outputFormat: "Output format"
        }
    }

    static func hint(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "What you want done, in your own words."
        case .context: "Background the model cannot see on its own."
        case .constraints: "Rules it must follow, one per line."
        case .examples: "A sample of what good looks like."
        case .outputFormat: "How the answer should be shaped."
        }
    }
}
#endif
```

- [ ] **Step 2: Write `CompiledPromptPane.swift`.**

```swift
#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import AppKit

/// Right column: exactly what the frontier model will receive, plus target and Copy.
struct CompiledPromptPane: View {
    @Environment(AppServices.self) private var services
    @State private var copied = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        if let brief = model.selected, let compiled = model.compiled {
            VStack(alignment: .leading, spacing: 12) {
                targetPicker(brief)
                meter(brief, compiled)
                ForEach(Array(compiled.warnings.enumerated()), id: \.offset) { _, w in
                    Label(w.message, systemImage: "exclamationmark.triangle")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                ScrollView {
                    Text(compiled.text.isEmpty ? "Your prompt appears here as you write the goal." : compiled.text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(10)
                }
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                copyBar
            }
            .padding(16)
            .background(Color.mtSurfaceContainerLowest)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 40))
                    .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
                Text("The finished prompt shows here").font(.mtTitleMedium)
                    .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mtSurfaceContainerLowest)
        }
    }

    private func targetPicker(_ brief: Brief) -> some View {
        HStack {
            Picker("Model", selection: Binding(get: { brief.target.modelFamily },
                                               set: { model.setTarget(modelFamily: $0, surface: brief.target.surface) })) {
                Text("Claude").tag("claude"); Text("GPT").tag("gpt"); Text("Other").tag("generic")
            }
            Picker("Where", selection: Binding(get: { brief.target.surface },
                                               set: { model.setTarget(modelFamily: brief.target.modelFamily, surface: $0) })) {
                ForEach(Surface.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        .pickerStyle(.menu)
    }

    private func meter(_ brief: Brief, _ compiled: CompiledPrompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(Double(compiled.tokens), Double(brief.target.tokenBudget)),
                         total: Double(max(brief.target.tokenBudget, 1)))
            Text("About \(compiled.tokens.formatted()) of \(brief.target.tokenBudget.formatted()) tokens")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private var copyBar: some View {
        HStack {
            Button { copy(nil) } label: { Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                .buttonStyle(MTFilledButtonStyle())
                .disabled(model.copyText(for: nil).isEmpty)
            Menu("Copy for…") {
                Button("Claude Code") { copy(.claudeCode) }
                Button("ChatGPT") { copy(.chatGPTWeb) }
            }
            .disabled(model.copyText(for: nil).isEmpty)
        }
    }

    private func copy(_ surface: Surface?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyText(for: surface), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
#endif
```

- [ ] **Step 3: Route in `ContentView.swift`.** Change the default `selectedDestination` to `.briefs`; add `case .briefs: BriefWorkbenchView()` to `contentPanel`; in `detailPanel`, add an `if selectedDestination == .briefs { CompiledPromptPane() } else if ...` first branch; add `.briefs` to the `default` of `badge(for:)` (already covered by `default`).

- [ ] **Step 4: Build and look.** Run `Scripts/dev-run.sh`, then screenshot the app. Expected: sidebar shows Briefs, Library, Models / Quick ask, MCP Tools, Settings; center shows the "No briefs yet" empty state; right shows "The finished prompt shows here". Create a brief, type a goal, confirm the right pane updates and Copy works (paste into a scratch field or `pbpaste`).

- [ ] **Step 5: Commit Tasks 2 and 3 together**

```bash
git add Sources/VibeCockpit/App/NavDestination.swift Sources/VibeCockpit/App/AppServices.swift \
  Sources/VibeCockpit/UI/Briefs Sources/VibeCockpit/UI/ContentView.swift Tests/VibeCockpitTests/NavigationTests.swift
git commit -m "feat(briefs): workbench UI with compiled prompt pane and prompt-first navigation"
```

---

### Task 4: Improve the Goal with the existing review sheet

**Files:**
- Modify: `Sources/VibeCockpit/UI/Briefs/BriefWorkbenchView.swift`

**Interfaces:**
- Consumes: `PromptStudioModel.startOptimize(draft:mode:intent:)`, `OptimizeReviewSheet(studio:draft:onAccept:onExpand:onAskQuestions:onClose:)` (signature as used in `IntentPane.swift:47-58`), `BriefWorkbenchModel.setText`.
- Produces: an "Improve" button on the Goal section; accepting the reviewed text replaces the Goal; closing changes nothing.

- [ ] **Step 1:** Add `@State private var improving = false` and, in the Goal section header only, a `Button("Improve") { improving = true }` disabled when the goal is empty. Add:

```swift
.sheet(isPresented: $improving) {
    OptimizeReviewSheet(
        studio: services.promptStudio, draft: model.selected?.text(of: .goal) ?? "",
        onAccept: { model.setText($0, for: .goal); improving = false },
        onExpand: { services.promptStudio.startOptimize(draft: model.selected?.text(of: .goal) ?? "", mode: .expand, intent: "") },
        onAskQuestions: { qs in
            let old = model.selected?.text(of: .goal) ?? ""
            model.setText(old + "\n\n" + qs.map { "Q: \($0)\nA: " }.joined(separator: "\n"), for: .goal)
            services.promptStudio.dismissReview(); improving = false
        },
        onClose: { improving = false })
}
```

If `startOptimize`'s `intent:` parameter rejects an empty string, pass `"general"` (check `PromptEngineer.Intent` for the neutral case).

- [ ] **Step 2:** `Scripts/dev-run.sh`. With a model loaded, write a rough goal, press Improve, confirm the diff sheet opens, Accept updates the Goal and the right pane, and Close leaves the Goal unchanged. If no model is loaded, confirm the sheet shows a plain-sentence failure and the Goal is unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/VibeCockpit/UI/Briefs/BriefWorkbenchView.swift
git commit -m "feat(briefs): improve the goal through the existing review sheet"
```

---

### Task 5: Copy and empty-state pass, docs

**Files:**
- Modify: `Sources/VibeCockpit/UI/ContentView.swift` (`detailPlaceholder`), `Sources/VibeCockpit/UI/IntentPane.swift` (chat header/empty state), `CLAUD.md`

- [ ] **Step 1:** In `IntentPane`, give the empty chat one line of guidance: "Quick questions only. Build the real prompt in Briefs." (a `Text` shown when `intentHistory.isEmpty`, inside `historyList`).
- [ ] **Step 2:** In `CLAUD.md`, under the product-direction note, add: "Phase 2 shipped: Briefs workbench is the default center; chat is 'Quick ask'. Phases 3–6 pending."
- [ ] **Step 3:** `swift test --parallel` (rerun `ModelInstaller` alone if it flakes), then `Scripts/dev-run.sh` and screenshot every sidebar item to confirm no stale IDE wording remains.
- [ ] **Step 4: Commit**

```bash
git add Sources/VibeCockpit/UI/ContentView.swift Sources/VibeCockpit/UI/IntentPane.swift CLAUD.md
git commit -m "docs+copy: quick-ask guidance and phase 2 status"
```

## Self-review

- **Spec coverage (phase 2):** editor with per-section token counts (Task 3), compiled pane with target picker, meter, warnings, Copy and copy variants (Tasks 1, 3), reuse of the proposal sheet (Task 4), nav per spec minus Context (Task 2). Deliberately left out: interview rail and lint chips (phase 4), diff against previous version (phase 5), removing `augmentUserTurn` (not before phase 4).
- **Type consistency:** `copyText(for: Surface?)`, `setTarget(modelFamily:surface:)`, `setText(_:for:)`, `setEnabled(_:for:)` are the same in Tasks 1, 3 and 4.
- **Risk:** the `flush()` chaining in Task 1 is the subtle part; its tests pin it.
