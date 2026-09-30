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
        let brief = Brief.new(title: name.isEmpty ? "Untitled brief" : name,
                              target: .make(modelFamily: "claude", surface: .claudeCode))
        briefs.insert(brief, at: 0)
        selectedID = brief.id
        recompile()
        do { try await store.save(brief) } catch { saveError = error.localizedDescription }
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

    /// Replaces the selected brief wholesale (used by later context and version features).
    public func replaceSelected(with brief: Brief) {
        mutate { $0 = brief; $0.updatedAt = Date() }
    }

    private func mutate(_ change: (inout Brief) -> Void) {
        guard let i = briefs.firstIndex(where: { $0.id == selectedID }) else { return }
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
