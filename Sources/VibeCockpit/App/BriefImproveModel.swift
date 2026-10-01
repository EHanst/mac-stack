import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Coordinates the Improve workspace in the right pane. Unlike the old review sheet, it owns the
/// whole working session: the revision text, chat-edit undo stack, optimizer phase mirror, and
/// accept/expand/continue flows.
@MainActor
@Observable
public final class BriefImproveModel {
    public enum ChatEditPhase: Equatable {
        case idle, editing
        case failed(String)
    }

    public var presentedBriefID: String?
    public private(set) var briefID: String?
    public private(set) var revision: String = ""
    public private(set) var originalText: String = ""
    public private(set) var optimizerPhase: PromptStudioModel.Phase = .idle
    public private(set) var chatEditPhase: ChatEditPhase = .idle

    public var canUndoEdit: Bool { !undoStack.isEmpty }

    private struct UndoEntry { let revision: String }
    private var undoStack: [UndoEntry] = []
    private let sidecar: BriefSidecar
    private let workbench: BriefWorkbenchModel
    private var chatTask: Task<Void, Never>?
    private var chatGeneration = 0
    private var mustNotShrink = false

    public init(sidecar: BriefSidecar, workbench: BriefWorkbenchModel) {
        self.sidecar = sidecar
        self.workbench = workbench
    }

    public func open(_ brief: Brief, studio: PromptStudioModel) {
        open(brief.effectiveBody, brief: brief, studio: studio)
    }

    public func open(_ text: String, brief: Brief, studio: PromptStudioModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !studio.isRunning else { return }

        chatTask?.cancel()
        chatGeneration += 1
        chatEditPhase = .idle
        undoStack.removeAll()

        // A draft from a previous session is recoverable before the new round overwrites it.
        workbench.snapshotDraftIfChanged(id: brief.id, newStartingText: trimmed)

        briefID = brief.id
        presentedBriefID = brief.id
        originalText = trimmed
        revision = trimmed
        mustNotShrink = false

        startOptimize(trimmed, studio: studio, mode: .improve)
    }

    public func close() {
        persistDraft()
        chatTask?.cancel()
        chatGeneration += 1
        chatTask = nil
        presentedBriefID = nil
        briefID = nil
        originalText = ""
        revision = ""
        undoStack.removeAll()
        chatEditPhase = .idle
        optimizerPhase = .idle
    }

    public func keepMine() { close() }

    public func accept() {
        guard let id = briefID else { return }
        let text = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commit(text, briefID: id)
        revision = ""
        close()
    }

    public func acceptAndContinue(studio: PromptStudioModel) {
        guard let id = briefID, let brief = currentBrief() else { return }
        let text = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !studio.isRunning else { return }
        commit(text, briefID: id)

        originalText = text
        revision = text
        undoStack.removeAll()
        chatTask?.cancel()
        chatGeneration += 1
        chatEditPhase = .idle
        mustNotShrink = true

        startOptimize(text, studio: studio, mode: .improve)
    }

    private func commit(_ text: String, briefID id: String) {
        workbench.snapshotIfChanged(id: id)
        workbench.setBody(text, briefID: id)
        workbench.saveVersion(id: id)
        workbench.setDraft(nil, briefID: id)
    }

    public func applyEdit(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let brief = currentBrief(), let id = briefID else { return }

        if chatEditPhase == .editing { return }
        if case .running = optimizerPhase { return }

        chatTask?.cancel()
        chatGeneration += 1
        let generation = chatGeneration
        let base = revision
        undoStack.append(UndoEntry(revision: base))
        chatEditPhase = .editing

        chatTask = Task { [sidecar, workbench] in
            do {
                var editBrief = brief
                editBrief.body = base
                editBrief.inputAtEdit = brief.inputAtEdit
                let revised = try await sidecar.edit(brief: editBrief, instruction: trimmed)
                try Task.checkCancellation()
                guard generation == self.chatGeneration else { return }

                self.revision = revised
                workbench.setDraft(revised, briefID: id)
                workbench.setInput(trimmed, briefID: id)
                self.chatEditPhase = .idle
            } catch is CancellationError {
                // cancel() already reset the session state as needed.
            } catch {
                guard generation == self.chatGeneration else { return }
                self.chatEditPhase = .failed(error.localizedDescription)
            }
        }
    }

    public func undoEdit() {
        guard let id = briefID, !undoStack.isEmpty else { return }
        let entry = undoStack.removeLast()
        revision = entry.revision
        workbench.setDraft(entry.revision, briefID: id)
        chatEditPhase = .idle
        chatTask?.cancel()
        chatGeneration += 1
        chatTask = nil
    }

    public func setRevision(_ text: String) {
        guard let id = briefID else { return }
        revision = text
        workbench.setDraft(text, briefID: id)
        undoStack.removeAll()
        chatTask?.cancel()
        chatGeneration += 1
        chatTask = nil
        chatEditPhase = .idle
    }

    public func expand(studio: PromptStudioModel) {
        guard currentBrief() != nil, !studio.isRunning else { return }
        let base = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        persistDraft()
        undoStack.removeAll()
        mustNotShrink = false
        startOptimize(base, studio: studio, mode: .expand)
    }

    public func cancelOptimize(studio: PromptStudioModel) {
        studio.cancelOptimize()
        optimizerPhase = .idle
        mustNotShrink = false
        if revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            revision = originalText
            persistDraft()
        }
    }

    /// Mirror PromptStudioModel's phase and pull out the useful revision.
    /// In follow-up rounds (`mustNotShrink`), a shorter proposed revision is rejected.
    public func receiveOptimizerPhase(_ phase: PromptStudioModel.Phase) {
        optimizerPhase = phase
        switch phase {
        case .idle:
            if revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                revision = originalText
                persistDraft()
            }
        case .running:
            break
        case .failed:
            if revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                revision = originalText
            }
            persistDraft()
        case .review(let result):
            let candidate = result.improved.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.rejection == nil && result.didChange && !candidate.isEmpty {
                if mustNotShrink && candidate.count < revision.trimmingCharacters(in: .whitespacesAndNewlines).count {
                    optimizerPhase = .failed("The follow-up round would shrink the brief, so I kept the current revision.")
                } else {
                    revision = candidate
                }
            } else if revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                revision = originalText
            }
            mustNotShrink = false
            undoStack.removeAll()
            persistDraft()
        }
    }

    private func startOptimize(_ text: String, studio: PromptStudioModel, mode: OptimizeMode) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        optimizerPhase = .running(partial: "")
        studio.startOptimize(draft: text, mode: mode, intent: PromptEngineer.Intent.general.rawValue)
    }

    private func currentBrief() -> Brief? {
        guard let id = briefID else { return nil }
        return workbench.briefs.first { $0.id == id }
    }

    private func persistDraft() {
        guard let id = briefID else { return }
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        workbench.setDraft(trimmed.isEmpty ? nil : trimmed, briefID: id)
    }
}
