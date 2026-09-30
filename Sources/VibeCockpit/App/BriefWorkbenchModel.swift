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
    /// Set by `AppServices`; nil means no project or index is available.
    public var contextSource: BriefContextSource?
    /// Called when the user does something that means "this brief is good": saves a version, copies the
    /// compiled prompt or exports it. The knowledge recorder listens; nothing here depends on it.
    public var onBriefAccepted: (@MainActor (Brief) -> Void)?

    private let store: BriefStore
    private let saveDelay: Duration
    /// One save chain per brief, so editing B never cancels A's pending write.
    private var pendingSaves: [String: Task<Void, Never>] = [:]
    private var saveGeneration: [String: Int] = [:]

    public init(store: BriefStore, saveDelay: Duration = .milliseconds(300)) {
        self.store = store
        self.saveDelay = saveDelay
    }

    public var selected: Brief? { briefs.first { $0.id == selectedID } }

    public func reload() async {
        await flushNow()
        briefs = await store.all()
        if selected == nil { selectedID = briefs.first?.id }
        recompile()
    }

    public func newBrief(title: String) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await insert(Brief.new(title: name.isEmpty ? "Untitled brief" : name,
                               target: .make(modelFamily: "claude", surface: .claudeCode)))
    }

    /// The clipboard text becomes the goal as it is; redaction happens when the prompt is compiled,
    /// exported or sent to the model. False when there is nothing to use.
    @discardableResult
    public func newBrief(fromClipboard text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var brief = Brief.new(title: String(ContextRedactor.redact(first).text.prefix(40)).trimmingCharacters(in: .whitespaces),
                              target: .make(modelFamily: "claude", surface: .claudeCode))
        brief.setText(text, for: .goal)
        await insert(brief)
        return true
    }

    public func newBrief(title: String, goal: String, context: String) async {
        var brief = Brief.new(title: title, target: .make(modelFamily: "claude", surface: .claudeCode))
        brief.setText(goal, for: .goal)
        brief.setText(context, for: .context)
        await insert(brief)
    }

    private func insert(_ brief: Brief) async {
        briefs.insert(brief, at: 0)
        selectedID = brief.id
        recompile()
        do { try await store.save(brief) } catch { saveError = error.localizedDescription }
    }

    public func select(_ id: String?) { selectedID = id; recompile() }

    public func setText(_ text: String, for kind: BriefSection.Kind) {
        mutate { $0.setText(text, for: kind) }
    }

    /// Sets a section of a named brief, which need not be the selected one. No-op if it no longer exists.
    public func setText(_ text: String, for kind: BriefSection.Kind, briefID: String) {
        guard briefs.contains(where: { $0.id == briefID }) else { return }
        mutate(id: briefID) { $0.setText(text, for: kind) }
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
        // Remove and reselect before any await, so a second call sees the new state, not this one.
        briefs.remove(at: index)
        selectedID = briefs.isEmpty ? nil : briefs[min(index, briefs.count - 1)].id
        recompile()
        // Let an in-flight write finish (it skips itself once the brief is gone), then delete the file.
        await pendingSaves[id]?.value
        pendingSaves[id] = nil
        saveGeneration[id] = nil
        do { try await store.delete(id: id) } catch let BriefStoreError.notFound { /* never reached disk */ }
        catch { saveError = error.localizedDescription }
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

    // MARK: Versions

    /// Records the current sections as a version unless nothing changed since the last one or there is no goal.
    /// `id` pins the brief; nil means the selected one.
    public func saveVersion(id: String? = nil) {
        guard let brief = briefs.first(where: { $0.id == (id ?? selectedID) }) else { return }
        let goal = brief.sections.first { $0.kind == .goal }
        guard goal?.enabled == true, !(goal?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if brief.versions.last?.sections != brief.sections { snapshotIfChanged(id: brief.id) }
        noteAccepted(id: brief.id)
    }

    private func noteAccepted(id: String?) {
        guard let brief = briefs.first(where: { $0.id == (id ?? selectedID) }) else { return }
        let goal = brief.sections.first { $0.kind == .goal }
        guard goal?.enabled == true, !(goal?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onBriefAccepted?(brief)
    }

    /// Like `saveVersion` but with no goal requirement: used before an edit that would overwrite text,
    /// where losing it is worse than keeping an odd version.
    public func snapshotIfChanged(id: String) {
        guard let brief = briefs.first(where: { $0.id == id }), brief.versions.last?.sections != brief.sections else { return }
        mutate(id: id) { $0.snapshot() }
    }

    /// Puts an older version's sections back. The current sections are saved first so restoring can be undone.
    public func restoreVersion(_ index: Int) {
        guard let brief = selected, brief.versions.indices.contains(index) else { return }
        let sections = brief.versions[index].sections
        mutate { b in
            if b.versions.last?.sections != b.sections { b.snapshot() }
            b.sections = sections
            b.updatedAt = Date()
        }
    }

    /// `copyText`, plus a version, because what was sent is worth being able to get back.
    public func copyForClipboard(for surface: Surface?) -> String {
        let text = copyText(for: surface)
        if !text.isEmpty { saveVersion() }
        return text
    }

    // MARK: Export

    public func exportRoots() async -> [URL] { await contextSource?.roots() ?? [] }

    /// Writes the selected brief to `<root>/.vibe/briefs/` and returns one sentence for the user.
    public func exportSelected(to root: URL) -> String {
        guard let brief = selected else { return "Pick a brief first." }
        do {
            let file = try BriefExporter.export(brief, toProjectRoot: root)
            saveVersion()
            let base = root.resolvingSymlinksInPath().path + "/"
            let full = file.resolvingSymlinksInPath().path
            return "Saved to " + (full.hasPrefix(base) ? String(full.dropFirst(base.count)) : file.lastPathComponent)
        } catch {
            return error.localizedDescription
        }
    }

    /// Every saved brief, with pending edits written first. For outside readers such as MCP.
    public func allBriefs() async -> [Brief] { await flushNow(); return await store.all() }

    /// Waits for pending edits to reach disk on their normal schedule.
    public func flush() async { for task in Array(pendingSaves.values) { await task.value } }

    /// Writes pending edits now instead of waiting out the delay. Used before quitting and reloading.
    public func flushNow() async {
        for task in pendingSaves.values { task.cancel() }   // wakes the sleeping delay; the write still happens
        await flush()
    }

    /// True when the compiled prompt has a goal to send. Reads the cached compile, never recompiles.
    public var canCopy: Bool {
        guard let compiled else { return false }
        return !compiled.warnings.contains { $0.code == .emptyGoal }
    }

    // MARK: Context

    public var contextTokens: Int {
        selected?.contextItems.filter(\.included).reduce(0) { $0 + $1.tokens } ?? 0
    }

    /// Adds items; one with an id already present is refreshed in place and keeps its include switch.
    public func addContext(_ items: [ContextItem]) { addContext(items, to: nil) }

    /// `id` pins the target brief; nil means whichever is selected now.
    private func addContext(_ items: [ContextItem], to id: String?) {
        mutate(id: id) { brief in
            for var item in items {
                if let i = brief.contextItems.firstIndex(where: { $0.id == item.id }) {
                    item.included = brief.contextItems[i].included
                    brief.contextItems[i] = item
                } else {
                    brief.contextItems.append(item)
                }
            }
            brief.updatedAt = Date()
        }
    }

    public func removeContext(id: String) {
        mutate { $0.contextItems.removeAll { $0.id == id }; $0.updatedAt = Date() }
    }

    public func setContextIncluded(_ on: Bool, id: String) { editItem(id) { $0.included = on } }
    public func setContextMode(_ mode: ContextMode, id: String) { editItem(id) { $0.mode = mode } }

    private func editItem(_ id: String, _ change: (inout ContextItem) -> Void) {
        mutate { brief in
            guard let i = brief.contextItems.firstIndex(where: { $0.id == id }) else { return }
            change(&brief.contextItems[i]); brief.updatedAt = Date()
        }
    }

    /// Search hits for `query`, as items ready to add. Empty when there is no index; throws if search itself failed.
    public func searchContext(_ query: String) async throws -> [ContextItem] {
        guard let source = contextSource, let brief = selected else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let roots = await source.roots()
        let hits = try await source.search(trimmed)
        var seen = Set<String>()
        return hits.map {
            ContextItemFactory.hit(filePath: $0.filePath, kind: $0.declarationKind, content: $0.content,
                                   query: trimmed, roots: roots, surface: brief.target.surface)
        }.filter { seen.insert($0.id).inserted }
    }

    public func addFile(_ url: URL) async throws {
        guard let source = contextSource, let brief = selected else { throw ContextItemError.noWorkspace }
        let id = brief.id, surface = brief.target.surface
        let roots = await source.roots()
        guard !roots.isEmpty else { throw ContextItemError.noWorkspace }
        // Reading happens off the main actor so a big or slow file cannot freeze typing.
        let item = try await Task.detached {
            try ContextItemFactory.file(at: url, roots: roots, surface: surface, provenance: "picked file")
        }.value
        addContext([item], to: id)
    }

    /// Adds the uncommitted changes of every project that has a repository. The result goes to the brief
    /// that was selected when this was called, however long git takes.
    public func addWorkingDiff() async throws {
        guard let source = contextSource, let id = selectedID else { throw ContextItemError.noWorkspace }
        let roots = await source.roots()
        guard !roots.isEmpty else { throw ContextItemError.noWorkspace }
        var items: [ContextItem] = []
        var firstError: Error?
        var sawEmpty = false
        for root in roots {
            do {
                let diff = try await source.workingDiff(root)
                if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sawEmpty = true; continue }
                items.append(ContextItemFactory.diff(diff, ref: "uncommitted changes in \(root.lastPathComponent)"))
            } catch {
                firstError = firstError ?? error
            }
        }
        if items.isEmpty {
            if let firstError, !sawEmpty { throw firstError }
            throw ContextItemError.noChanges
        }
        addContext(items, to: id)
    }

    /// Adds `text` to a section of the named brief (not necessarily the selected one). False if that
    /// brief no longer exists. Existing text is kept; a list-like section gets a new line, others a blank line.
    @discardableResult
    public func append(_ text: String, to kind: BriefSection.Kind, briefID: String) -> Bool {
        guard briefs.contains(where: { $0.id == briefID }) else { return false }
        mutate(id: briefID) { brief in
            let existing = brief.text(of: kind)
            let gap = existing.isEmpty ? "" : (kind == .constraints || kind == .examples ? "\n" : "\n\n")
            brief.setText(existing + gap + text, for: kind)
        }
        return true
    }

    /// Replaces the selected brief wholesale (used by later context and version features).
    public func replaceSelected(with brief: Brief) {
        mutate { $0 = brief; $0.updatedAt = Date() }
    }

    private func mutate(id: String? = nil, _ change: (inout Brief) -> Void) {
        guard let i = briefs.firstIndex(where: { $0.id == (id ?? selectedID) }) else { return }
        change(&briefs[i])
        recompile()
        scheduleSave(id: briefs[i].id)
    }

    private func scheduleSave(id: String) {
        let generation = (saveGeneration[id] ?? 0) + 1
        saveGeneration[id] = generation
        let previous = pendingSaves[id]
        let delay = saveDelay
        pendingSaves[id] = Task { [store] in
            await previous?.value
            try? await Task.sleep(for: delay)   // a flush cancels this sleep; the write below still runs
            // Superseded by a newer edit, or the brief was deleted: nothing to write.
            guard self.saveGeneration[id] == generation,
                  let brief = self.briefs.first(where: { $0.id == id }) else { return }
            do { try await store.save(brief) } catch { self.record(error) }
        }
    }

    private func record(_ error: Error) { saveError = error.localizedDescription }
    private func recompile() { compiled = selected.map(BriefCompiler.compile) }
}
