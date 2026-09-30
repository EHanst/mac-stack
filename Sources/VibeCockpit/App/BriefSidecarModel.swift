import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Runs interview and critique calls for the selected brief and holds their cards.
/// Cards are proposals: only `answer` and `accept` (a user click) write into a brief.
@MainActor
@Observable
public final class BriefSidecarModel {
    public enum Phase: Equatable {
        case idle
        case running(SidecarOperation)
        case failed(String)
    }

    public enum ContinuationPhase: Equatable {
        case idle, running
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var result: SidecarResult?
    /// The brief the cards belong to; the view shows them only while this is selected.
    public private(set) var briefID: String?

    private let sidecar: BriefSidecar
    /// Progress of "new brief from a pasted session", which has no brief yet to attach cards to.
    public private(set) var continuationPhase: ContinuationPhase = .idle

    private var task: Task<Void, Never>?
    private var generation = 0
    private var continuationTask: Task<Void, Never>?
    private var continuationGeneration = 0

    public init(sidecar: BriefSidecar) { self.sidecar = sidecar }

    public func run(_ operation: SidecarOperation, brief: Brief, reply: String? = nil) {
        task?.cancel()
        generation += 1
        let mine = generation
        phase = .running(operation)
        result = nil
        briefID = brief.id
        task = Task { [sidecar] in
            do {
                let out = try await sidecar.run(brief: brief, operation: operation, reply: reply)
                guard mine == self.generation else { return }
                self.result = out
                self.phase = .idle
            } catch is CancellationError {
                // cancel() already reset the state.
            } catch {
                guard mine == self.generation else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
    }

    public func clear() { cancel(); result = nil; briefID = nil }

    public func answer(_ q: SidecarQuestion, text: String, in workbench: BriefWorkbenchModel) {
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = briefID, !a.isEmpty, result?.questions.contains(q) == true else { return }
        workbench.append("Q: \(q.text)\nA: \(a)", to: q.section, briefID: id)
        result?.questions.removeAll { $0.id == q.id }
    }

    public func accept(_ f: SidecarFinding, in workbench: BriefWorkbenchModel) {
        guard let id = briefID, let addition = f.addition, result?.findings.contains(f) == true else { return }
        workbench.append(addition, to: f.section, briefID: id)
        result?.findings.removeAll { $0.id == f.id }
    }

    /// Applies a proposed rewrite to the brief it was made for, if that section is still as it was.
    /// The text before the rewrite is saved as a version first, so it can be restored.
    public func acceptRevision(_ r: SidecarRevision, in workbench: BriefWorkbenchModel) {
        guard let id = briefID, result?.revisions.contains(r) == true,
              let brief = workbench.briefs.first(where: { $0.id == id }) else { return }
        result?.revisions.removeAll { $0.id == r.id }
        guard brief.text(of: r.section) == r.original else {
            result?.note = "That section changed since the suggestion. Run it again."
            return
        }
        workbench.snapshotIfChanged(id: id)
        workbench.setText(r.proposed, for: r.section, briefID: id)
    }

    public func dismiss(revisionID: String) { result?.revisions.removeAll { $0.id == revisionID } }

    /// Summarizes a pasted session into a new brief. Nothing is created unless the model's summary is usable.
    public func continueFromSession(_ pasted: String, in workbench: BriefWorkbenchModel) {
        continuationTask?.cancel()
        continuationGeneration += 1
        let mine = continuationGeneration
        continuationPhase = .running
        continuationTask = Task { [sidecar] in
            do {
                let draft = try await sidecar.continuation(from: pasted)
                guard mine == self.continuationGeneration else { return }
                await workbench.newBrief(title: draft.title, goal: draft.goal, context: draft.context)
                guard mine == self.continuationGeneration else { return }
                self.clear()
                self.continuationPhase = .idle
            } catch is CancellationError {
                // cancelContinuation() already reset the state.
            } catch {
                guard mine == self.continuationGeneration else { return }
                self.continuationPhase = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelContinuation() {
        continuationGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
        continuationPhase = .idle
    }

    public func dismiss(questionID: String) { result?.questions.removeAll { $0.id == questionID } }
    public func dismiss(findingID: String) { result?.findings.removeAll { $0.id == findingID } }
}
