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

    public private(set) var phase: Phase = .idle
    public private(set) var result: SidecarResult?
    /// The brief the cards belong to; the view shows them only while this is selected.
    public private(set) var briefID: String?

    private let sidecar: BriefSidecar
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(sidecar: BriefSidecar) { self.sidecar = sidecar }

    public func run(_ operation: SidecarOperation, brief: Brief) {
        task?.cancel()
        generation += 1
        let mine = generation
        phase = .running(operation)
        result = nil
        briefID = brief.id
        task = Task { [sidecar] in
            do {
                let out = try await sidecar.run(brief: brief, operation: operation)
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

    public func dismiss(questionID: String) { result?.questions.removeAll { $0.id == questionID } }
    public func dismiss(findingID: String) { result?.findings.removeAll { $0.id == findingID } }
}
