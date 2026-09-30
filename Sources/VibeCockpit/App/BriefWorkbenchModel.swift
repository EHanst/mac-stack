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
    private var pendingSave: Task<Void, Never>?

    public init(store: BriefStore, saveDelay: Duration = .milliseconds(300)) {
        self.store = store
        self.saveDelay = saveDelay
    }

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
        await flush()
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
        let previous = pendingSave
        previous?.cancel()
        let delay = saveDelay
        pendingSave = Task { [store] in
            await previous?.value
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do { try await store.save(brief) } catch { await self.record(error) }
        }
    }

    private func record(_ error: Error) { saveError = error.localizedDescription }
    private func recompile() { compiled = selected.map(BriefCompiler.compile) }
}
