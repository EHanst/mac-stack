import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Runs direct plain-language edits on the brief body via the sidecar, with a per‑brief undo stack,
/// and provides brainstorming questions/tips for the banner.
@MainActor
@Observable
public final class BriefFeedbackModel {
    public enum FeedbackPhase: Equatable {
        case idle, editing
        case failed(String)
    }

    public enum BrainstormPhase: Equatable {
        case idle, running
        case failed(String)

        public var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    public private(set) var phase: FeedbackPhase = .idle
    public private(set) var brainstormPhase: BrainstormPhase = .idle
    public private(set) var questions: [SidecarQuestion] = []
    public private(set) var tips: [String] = []

    private struct UndoEntry {
        let body: String?
        let inputAtEdit: String?
    }

    private let sidecar: BriefSidecar
    private let workbench: BriefWorkbenchModel
    private var undoStacks: [String: [UndoEntry]] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var editingBriefID: String?
    private var brainstormTask: Task<Void, Never>?
    private var brainstormGeneration = 0
    private var lastBrainstormBody: String?

    public init(sidecar: BriefSidecar, workbench: BriefWorkbenchModel) {
        self.sidecar = sidecar
        self.workbench = workbench
    }

    public func send(_ instruction: String, brief: Brief) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        task?.cancel()
        generation += 1
        let mine = generation
        editingBriefID = brief.id
        let previousBody = brief.body
        let previousInputAtEdit = brief.inputAtEdit
        phase = .editing

        task = Task { [sidecar, workbench] in
            do {
                let revised = try await sidecar.edit(brief: brief, instruction: trimmed)
                try Task.checkCancellation()
                guard mine == self.generation else { return }

                // Stale check: same brief and effectiveBody unchanged since the edit started.
                guard let current = workbench.briefs.first(where: { $0.id == brief.id }),
                      current.effectiveBody == brief.effectiveBody else {
                    self.phase = .failed("The brief changed while editing.")
                    self.editingBriefID = nil
                    return
                }

                workbench.snapshotIfChanged(id: brief.id)
                workbench.setBody(revised, briefID: brief.id)

                // Push the state we captured before the edit.
                self.undoStacks[brief.id, default: []].append(
                    UndoEntry(body: previousBody, inputAtEdit: previousInputAtEdit)
                )

                self.phase = .idle
                self.editingBriefID = nil
            } catch is CancellationError {
                // cancel() already reset the state.
            } catch {
                guard mine == self.generation else { return }
                self.phase = .failed(error.localizedDescription)
                self.editingBriefID = nil
            }
        }
    }

    public func undo(briefID: String) {
        guard var stack = undoStacks[briefID], !stack.isEmpty else { return }
        let entry = stack.removeLast()
        undoStacks[briefID] = stack

        workbench.snapshotIfChanged(id: briefID)
        if let body = entry.body {
            workbench.restoreBody(body, inputAtEdit: entry.inputAtEdit, briefID: briefID)
        } else {
            workbench.restoreBody(nil, inputAtEdit: nil, briefID: briefID)
        }
    }

    public func canUndo(briefID: String) -> Bool {
        undoStacks[briefID]?.isEmpty == false
    }

    public func cancel() {
        task?.cancel()
        generation += 1
        task = nil
        phase = .idle
        editingBriefID = nil
    }

    /// `force` (the refresh button) reruns even when the brief hasn't changed since the last run.
    public func refreshBrainstorm(brief: Brief, force: Bool = false) {
        brainstormTask?.cancel()
        brainstormGeneration += 1
        let mine = brainstormGeneration
        let body = brief.effectiveBody

        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            questions = []
            tips = []
            brainstormPhase = .idle
            lastBrainstormBody = nil
            return
        }

        if !force, lastBrainstormBody == body {   // unchanged since last run
            brainstormPhase = .idle
            return
        }

        brainstormPhase = .running
        brainstormTask = Task { [sidecar] in
            do {
                let result = try await sidecar.brainstorm(brief: brief)
                try Task.checkCancellation()
                guard mine == self.brainstormGeneration else { return }
                self.questions = result.questions
                self.tips = result.tips
                self.lastBrainstormBody = body
                self.brainstormPhase = .idle
            } catch is CancellationError {
                // cancelled by a newer refresh or dismiss
            } catch {
                guard mine == self.brainstormGeneration else { return }
                self.brainstormPhase = .failed(error.localizedDescription)
            }
        }
    }

    public func dismissBrainstorm() {
        brainstormTask?.cancel()
        brainstormGeneration += 1
        brainstormTask = nil
        questions = []
        tips = []
        lastBrainstormBody = nil
        brainstormPhase = .idle
    }
}
