import Testing
import Foundation
@testable import KororoCore
@testable import StackCore

@MainActor
@Suite("BriefWorkbenchModel")
struct BriefWorkbenchModelTests {
    private func make() -> (BriefWorkbenchModel, BriefStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        return (BriefWorkbenchModel(store: store, saveDelay: .zero), store)
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
        m.setInput("Add a retry to the upload call")
        #expect(m.compiled?.text.contains("Add a retry") == true)
        await m.flush()
        #expect(await store.all().first?.input == "Add a retry to the upload call")
    }

    @Test("rapid edits end with the last one on disk")
    func rapidEdits() async {
        let (m, store) = make()
        await m.newBrief(title: "t")
        for i in 0..<20 { m.setInput("edit \(i)") }
        await m.flush()
        #expect(await store.all().first?.input == "edit 19")
    }

    @Test("copy for machine is exactly the compiled machine text the panel shows")
    func machineCopyMatchesView() async throws {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("## Goal\n\nFix the **login** timeout.")
        let brief = try #require(m.selected)
        #expect(m.copyText(for: nil, compact: true) == BriefCompiler.compile(brief, compact: true).text)
    }

    @Test("empty goal warns and copy text is empty")
    func emptyInput() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        #expect(m.compiled?.warnings.contains { $0.code == .emptyInput } == true)
        #expect(m.copyText(for: nil).isEmpty)
    }

    @Test("changing surface keeps section text and recompiles")
    func surface() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("Do X")
        m.setTarget(modelFamily: "claude", surface: .chatGPTWeb)
        #expect(m.selected?.target.surface == .chatGPTWeb)
        #expect(m.selected?.input == "Do X")
    }

    @Test("copy for a surface does not change the brief's own target")
    func copyVariant() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("Do X")
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
        let m2 = BriefWorkbenchModel(store: BriefStore(directory: store.directory), saveDelay: .zero)
        await m2.reload()
        #expect(m2.briefs.count == 1)
    }

    // MARK: Review fixes

    @Test("two deletes racing on one brief do not crash or resurrect it")
    func concurrentDelete() async {
        let (m, store) = make()
        await m.newBrief(title: "only")
        m.setInput("pending edit")
        async let a: Void = m.deleteSelected()
        async let b: Void = m.deleteSelected()
        _ = await (a, b)
        await m.flushNow()
        #expect(m.briefs.isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("an edit to one brief is not lost when another brief is edited inside the delay")
    func editsAcrossBriefs() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        let m = BriefWorkbenchModel(store: store, saveDelay: .milliseconds(200))
        await m.newBrief(title: "a")
        let aID = m.selectedID!
        m.setInput("edit in A")
        await m.newBrief(title: "b")
        m.setInput("edit in B")
        await m.flushNow()
        let saved = await store.all()
        #expect(saved.first { $0.id == aID }?.input == "edit in A")
        #expect(saved.first { $0.id != aID }?.input == "edit in B")
    }

    @Test("flushNow writes immediately instead of waiting out the delay")
    func flushNowIsImmediate() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let store = BriefStore(directory: dir)
        let m = BriefWorkbenchModel(store: store, saveDelay: .seconds(30))
        await m.newBrief(title: "t")
        m.setInput("last words")
        let start = ContinuousClock.now
        await m.flushNow()
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(await store.all().first?.input == "last words")
    }

    @Test("reload keeps an edit that has not reached disk yet")
    func reloadKeepsPendingEdit() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        let m = BriefWorkbenchModel(store: BriefStore(directory: dir), saveDelay: .seconds(30))
        await m.newBrief(title: "t")
        m.setInput("fresh")
        await m.reload()
        #expect(m.selected?.input == "fresh")
    }

    @Test("canCopy follows the goal and does not need a second compile")
    func canCopy() async {
        let (m, _) = make()
        #expect(!m.canCopy)
        await m.newBrief(title: "t")
        #expect(!m.canCopy)
        m.setInput("Do X")
        #expect(m.canCopy)
        m.setInput("  ")
        #expect(!m.canCopy)
    }

    @Test("switching surface on an over-budget brief changes the warnings, not the text")
    func overBudgetSurface() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("Do X")
        var brief = m.selected!
        let big = String(repeating: "word ", count: 30_000)
        brief.contextItems = [ContextItem(kind: .snippet, ref: "a.swift", text: big, mode: .inline)]
        m.replaceSelected(with: brief)
        let before = m.compiled?.warnings.map(\.code) ?? []
        m.setTarget(modelFamily: "claude", surface: .chatGPTWeb)
        #expect(m.selected?.input == "Do X")
        #expect(m.compiled != nil)
        #expect(before.contains(.overBudget) || before.contains(.itemDowngraded) || before.contains(.itemDropped))
    }

    // MARK: Context

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
        await m.newBrief(title: "t"); m.setInput("Do X")
        m.addContext([ContextItem(id: "x", kind: .file, ref: "a.swift", text: "func a() {}", mode: .inline)])
        #expect(m.contextTokens > 0)
        #expect(m.compiled?.text.contains("func a() {}") == true)
        m.setContextMode(.reference, id: "x")
        #expect(m.compiled?.text.contains("func a() {}") == false)
        m.setContextIncluded(false, id: "x")
        #expect(m.contextTokens == 0)
        m.removeContext(id: "x")
        #expect(m.selected?.contextItems.isEmpty == true)
    }

    @Test("search results become items with the brief's surface mode; no source means no items")
    func search() async throws {
        let (m, _) = make()
        await m.newBrief(title: "t")
        #expect(try await m.searchContext("login").isEmpty)
        m.contextSource = BriefContextSource(
            roots: { [URL(fileURLWithPath: "/w")] },
            search: { _ in [SearchResult(chunkID: UUID(), filePath: "/w/S.swift", declarationKind: "func", content: "func f() {}", score: 1, rank: 1)] },
            workingDiff: { _ in "" })
        let items = try await m.searchContext("login")
        #expect(items.count == 1 && items[0].mode == .reference)
    }

    @Test("an empty working diff is reported, not added; a real one is added inline")
    func diff() async throws {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.contextSource = BriefContextSource(roots: { [URL(fileURLWithPath: "/w")] }, search: { _ in [] }, workingDiff: { _ in "" })
        await #expect(throws: ContextItemError.noChanges) { try await m.addWorkingDiff() }
        #expect(m.selected?.contextItems.isEmpty == true)
        m.contextSource = BriefContextSource(roots: { [URL(fileURLWithPath: "/w")] }, search: { _ in [] }, workingDiff: { _ in "+x" })
        try await m.addWorkingDiff()
        #expect(m.selected?.contextItems.first?.kind == .gitDiff)
    }

    @Test("without a workspace, adding a file or diff says so")
    func noWorkspace() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        await #expect(throws: ContextItemError.noWorkspace) { try await m.addWorkingDiff() }
        await #expect(throws: ContextItemError.noWorkspace) { try await m.addFile(URL(fileURLWithPath: "/w/a.swift")) }
    }

    @Test("a slow diff lands in the brief it was requested for, even if you switch briefs meanwhile")
    func diffFollowsRequestingBrief() async throws {
        let (m, _) = make()
        await m.newBrief(title: "first")
        let firstID = m.selectedID!
        await m.newBrief(title: "second")
        m.select(firstID)
        m.contextSource = BriefContextSource(
            roots: { [URL(fileURLWithPath: "/w")] }, search: { _ in [] },
            workingDiff: { _ in try await Task.sleep(for: .milliseconds(150)); return "+slow" })
        async let adding: Void = m.addWorkingDiff()
        try await Task.sleep(for: .milliseconds(30))
        m.select(m.briefs.first { $0.id != firstID }!.id)
        try await adding
        #expect(m.briefs.first { $0.id == firstID }?.contextItems.count == 1)
        #expect(m.selected?.contextItems.isEmpty == true)
    }

    @Test("with several projects every project's changes are added; a project that is not a repo is skipped")
    func multiRootDiff() async throws {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.contextSource = BriefContextSource(
            roots: { [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")] },
            search: { _ in [] },
            workingDiff: { root in
                if root.lastPathComponent == "b" { throw GitDiffError.notARepository }
                return "+change in \(root.lastPathComponent)"
            })
        try await m.addWorkingDiff()
        #expect(m.selected?.contextItems.count == 2)
    }

    @Test("if no project has a usable repository, the reason is reported")
    func multiRootAllFail() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.contextSource = BriefContextSource(roots: { [URL(fileURLWithPath: "/a")] }, search: { _ in [] },
                                             workingDiff: { _ in throw GitDiffError.notARepository })
        await #expect(throws: GitDiffError.notARepository) { try await m.addWorkingDiff() }
    }

    @Test("a failing search is reported to the caller")
    func searchFailure() async {
        struct Down: Error {}
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.contextSource = BriefContextSource(roots: { [URL(fileURLWithPath: "/w")] }, search: { _ in throw Down() },
                                             workingDiff: { _ in "" })
        await #expect(throws: Down.self) { _ = try await m.searchContext("x") }
    }

    @Test("appendToInput adds to the input, separated from existing text")
    func appendInput() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Fix login")
        #expect(m.appendToInput("File: Auth.swift", briefID: m.selectedID!))
        #expect(m.selected?.input == "Fix login\n\nFile: Auth.swift")
        #expect(m.appendToInput("x", briefID: "gone") == false)
    }

    @Test("appendToInput to a deleted brief does nothing and reports it")
    func appendToDeleted() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        let id = m.selectedID!
        await m.deleteSelected()
        #expect(!m.appendToInput("x", briefID: id))
    }

    @Test("appendToInput targets the named brief, not the selected one")
    func appendPinned() async {
        let (m, _) = make()
        await m.newBrief(title: "a"); let a = m.selectedID!
        await m.newBrief(title: "b")
        #expect(m.appendToInput("only a", briefID: a))
        #expect(m.selected?.input == "")
        #expect(m.briefs.first { $0.id == a }?.input == "only a")
    }

    @Test("saveVersion records once; unchanged text adds nothing")
    func saveVersionOnce() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Fix login")
        m.saveVersion(); m.saveVersion()
        #expect(m.selected?.versions.count == 1)
        m.setInput("Fix login and logout")
        m.saveVersion()
        #expect(m.selected?.versions.count == 2)
    }

    @Test("a body-only change is recorded as a new version")
    func saveVersionBodyOnly() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Fix login")
        m.saveVersion()
        m.setBody("Fix login, edited")
        m.saveVersion()
        #expect(m.selected?.versions.count == 2)
        m.setBody("Fix login, edited again")
        m.saveVersion()
        #expect(m.selected?.versions.count == 3)
        #expect(m.selected?.input == "Fix login")
    }

    @Test("empty input creates no version")
    func noVersionWithoutGoal() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.saveVersion()
        #expect(m.selected?.versions.isEmpty == true)
    }

    @Test("copyForClipboard returns the prompt and records a version")
    func copyRecords() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("Do X")
        #expect(m.copyForClipboard(for: nil).contains("Do X"))
        #expect(m.copyForClipboard(for: nil).contains("Do X"))
        #expect(m.selected?.versions.count == 1)
    }

    @Test("restore brings back old text and keeps the current text as a version")
    func restore() async {
        let (m, store) = make()
        await m.newBrief(title: "t")
        m.setInput("old goal")
        m.saveVersion()
        m.setInput("new goal")
        m.restoreVersion(0)
        #expect(m.selected?.input == "old goal")
        #expect(m.selected?.versions.last?.input == "new goal")
        #expect(m.compiled?.text.contains("old goal") == true)
        await m.flush()
        #expect(await store.all().first?.input == "old goal")
    }

    @Test("restore with a bad index does nothing; the version cap holds")
    func restoreBoundsAndCap() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("a")
        m.restoreVersion(5); m.restoreVersion(-1)
        #expect(m.selected?.input == "a")
        for i in 0..<(Brief.maxVersions + 5) { m.setInput("g\(i)"); m.saveVersion() }
        #expect(m.selected?.versions.count == Brief.maxVersions)
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("export writes the brief into the project and reports the path")
    func export() async throws {
        let (m, _) = make()
        await m.newBrief(title: "Fix login")
        m.setInput("Add a retry")
        let root = try tempRoot()
        let msg = m.exportSelected(to: root)
        #expect(msg.hasPrefix("Saved to .vibe/briefs/fix-login-"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".vibe/briefs").path)
        #expect(files.count == 1)
        #expect(m.selected?.versions.count == 1)
        _ = m.exportSelected(to: root)
        #expect(m.selected?.versions.count == 1)
    }

    @Test("export with no goal says so and writes nothing")
    func exportNoGoal() async throws {
        let (m, _) = make()
        await m.newBrief(title: "t")
        let root = try tempRoot()
        #expect(m.exportSelected(to: root) == "Write something first, then save.")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".vibe").path))
        #expect(m.selected?.versions.isEmpty == true)
    }

    @Test("export refuses a symlinked .vibe with the exporter's sentence")
    func exportSymlink() async throws {
        let (m, _) = make()
        await m.newBrief(title: "t"); m.setInput("g")
        let fm = FileManager.default
        let root = try tempRoot(), elsewhere = try tempRoot()
        try fm.createSymbolicLink(at: root.appendingPathComponent(".vibe"), withDestinationURL: elsewhere)
        #expect(m.exportSelected(to: root) == BriefExportError.outsideProject.errorDescription)
        #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("exportRoots is empty without a context source")
    func rootsEmpty() async {
        let (m, _) = make()
        #expect(await m.exportRoots().isEmpty)
    }

    @Test("a brief from the clipboard uses the text as goal and the first line as title")
    func fromClipboard() async {
        let (m, _) = make()
        let made = await m.newBrief(fromClipboard: "\n  Fix the flaky upload test\nmore detail")
        #expect(made)
        #expect(m.selected?.title == "Fix the flaky upload test")
        #expect(m.selected?.input == "\n  Fix the flaky upload test\nmore detail")
    }

    @Test("blank clipboard makes nothing")
    func blankClipboard() async {
        let (m, _) = make()
        #expect(await m.newBrief(fromClipboard: " \n\t") == false)
        #expect(m.briefs.isEmpty)
    }

    @Test("a secret on the clipboard is kept in the brief but never compiled")
    func clipboardSecret() async {
        let (m, _) = make()
        await m.newBrief(fromClipboard: "Deploy with AKIAIOSFODNN7EXAMPLE now")
        #expect(m.selected?.input.contains("AKIAIOSFODNN7EXAMPLE") == true)
        #expect(m.compiled?.text.contains("AKIAIOSFODNN7EXAMPLE") == false)
        #expect(m.copyText(for: nil).contains("AKIAIOSFODNN7EXAMPLE") == false)
    }

    @Test("a long first line is trimmed for the title")
    func longTitle() async {
        let (m, _) = make()
        await m.newBrief(fromClipboard: String(repeating: "word ", count: 40))
        #expect((m.selected?.title.count ?? 99) <= 40)
    }


    @Test("restoring at the version cap keeps the restored text and the current text")
    func restoreAtCap() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        for i in 0..<Brief.maxVersions { m.setInput("v\(i)"); m.saveVersion() }
        m.setInput("current")
        m.restoreVersion(0)
        #expect(m.selected?.input == "v0")
        #expect(m.selected?.versions.last?.input == "current")
        #expect(m.selected?.versions.count == Brief.maxVersions)
    }

    @Test("a secret on the clipboard is not in the title or the export file name")
    func clipboardSecretTitle() async throws {
        let (m, _) = make()
        await m.newBrief(fromClipboard: "Deploy with AKIAIOSFODNN7EXAMPLE now")
        #expect(m.selected?.title.contains("AKIAIOSFODNN7EXAMPLE") == false)
        let root = try tempRoot()
        _ = m.exportSelected(to: root)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".vibe/briefs").path)
        #expect(files.allSatisfy { !$0.lowercased().contains("akiaiosfodnn7example") })
    }

    @Test("saving a version and copying both report the brief as accepted")
    func acceptedHook() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        m.setInput("Add retry to uploads")
        var seen: [String] = []
        m.onBriefAccepted = { seen.append($0.id) }
        m.saveVersion()
        #expect(seen == [m.selectedID!])
        _ = m.copyForClipboard(for: nil)
        #expect(seen.count == 2)
    }

    @Test("a brief with no goal is not reported")
    func noGoalNoHook() async {
        let (m, _) = make()
        await m.newBrief(title: "t")
        var count = 0
        m.onBriefAccepted = { _ in count += 1 }
        m.saveVersion()
        _ = m.copyForClipboard(for: nil)
        #expect(count == 0)
    }

    @Test("setBody while linked sets body; editing body to equal input stays edited")
    func setBodyOwnership() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Original")
        m.setBody("Edited")
        #expect(m.selected?.body == "Edited")
        #expect(m.selected?.input == "Original")
        #expect(m.selected?.effectiveBody == "Edited")

        m.setBody("Original")
        #expect(m.selected?.body == "Original")
        #expect(m.selected?.isEdited == true)
    }

    @Test("appendToBody switches a linked brief to edited and keeps an edited brief edited")
    func appendsToBody() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Start")
        m.appendToBody("Extra")
        #expect(m.selected?.body == "Start\n\nExtra")
        m.appendToBody("Final")
        #expect(m.selected?.body == "Start\n\nExtra\n\nFinal")
    }

    @Test("appendToBody onto an empty body adds no leading blank lines")
    func appendsToEmptyBody() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Start")
        m.setBody("")
        m.appendToBody("Extra")
        #expect(m.selected?.body == "Extra")
    }

    @Test("restoreVersion restores input and body")
    func restoreOwnership() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "Input v1")
        m.setBody("Body v1")
        m.saveVersion()
        m.setInput("Input v2")
        m.setBody("Body v2")
        m.restoreVersion(0)
        #expect(m.selected?.input == "Input v1")
        #expect(m.selected?.body == "Body v1")
    }

    @Test("setBody with briefID writes to the specified brief, not the selected one")
    func setBodyWithBriefID() async throws {
        let (m, _) = make()
        await m.newBrief(title: "First", input: "Input 1")
        let firstID = m.selected?.id
        await m.newBrief(title: "Second", input: "Input 2")
        let secondID = m.selected?.id

        // Select second brief, then write to first
        #expect(m.selectedID == secondID)
        m.setBody("Body for first", briefID: firstID ?? "")

        // Check first brief was updated, second untouched
        let first = m.briefs.first { $0.id == firstID }
        let second = m.briefs.first { $0.id == secondID }
        #expect(first?.body == "Body for first")
        #expect(second?.body == nil)
        #expect(second?.input == "Input 2")
    }

    @Test("Claude brief with unclosed <context> tag yields unbalancedXML lint finding")
    func lintUnclosedContextTag() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "<context>some info")
        let warnings = m.compiled?.warnings ?? []
        #expect(warnings.contains { $0.message.contains("<context>") || $0.message.contains("tag") || $0.message.contains("closed") })
    }

    @Test("Claude brief with balanced <context> tag has no unbalancedXML lint finding")
    func lintBalancedContextTag() async {
        let (m, _) = make()
        await m.newBrief(title: "t", input: "<context>some info</context>")
        let warnings = m.compiled?.warnings ?? []
        #expect(!warnings.contains { $0.message.contains("tag") && $0.message.contains("closed") })
    }
}
