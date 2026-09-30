#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI

/// Ask / Critique buttons and the cards they produce, for the selected brief.
struct SidecarRailView: View {
    @Environment(AppServices.self) private var services
    @State private var answers: [String: String] = [:]
    @State private var showReply = false

    private var sidecar: BriefSidecarModel { services.sidecar }
    private var workbench: BriefWorkbenchModel { services.briefs }
    private func running(_ brief: Brief) -> Bool {
        if case .running = sidecar.phase { sidecar.briefID == brief.id } else { false }
    }

    var body: some View {
        if let brief = workbench.selected { content(brief) }
    }

    private func content(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { sidecar.run(.interview, brief: brief) } label: { Label("Ask me", systemImage: "questionmark.bubble") }
                    .disabled(running(brief))
                Button { sidecar.run(.critique, brief: brief) } label: { Label("Critique", systemImage: "checklist") }
                    .disabled(running(brief))
                Button { showReply = true } label: { Label("Paste reply", systemImage: "arrowshape.turn.up.left") }
                    .disabled(running(brief))
                    .help("Paste the answer you got back and get suggested changes to this brief")
                if running(brief) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { sidecar.cancel() }
                }
                Spacer()
            }
            if sidecar.briefID == brief.id, case .failed(let message) = sidecar.phase {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
            if sidecar.briefID == brief.id, let result = sidecar.result {
                if let note = result.note { Text(note).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant) }
                ForEach(result.questions) { questionCard($0) }
                ForEach(result.findings) { findingCard($0) }
                ForEach(result.revisions) { revisionCard($0, briefID: brief.id) }
            }
        }
        .padding(12)
        .background(Color.mtSurfaceContainerHighest.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .sheet(isPresented: $showReply) {
            ReplySheet(title: "Paste the reply",
                       prompt: "Paste the answer from Claude Code or ChatGPT. The sidecar suggests changes to this brief; nothing changes until you apply one.",
                       action: "Suggest changes",
                       onSubmit: { sidecar.run(.revise, brief: brief, reply: $0) },
                       onClose: { showReply = false })
        }
    }

    private func revisionCard(_ r: SidecarRevision, briefID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BriefWorkbenchView.title(r.section)).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
            BriefVersionsSheet.diffText(WordDiff.segments(from: r.original, to: r.proposed)).font(.mtBodyMedium)
            HStack {
                Button("Apply") { sidecar.acceptRevision(r, in: workbench) }
                Button("Dismiss") { sidecar.dismiss(revisionID: r.id) }
            }
        }
    }

    private func questionCard(_ q: SidecarQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BriefWorkbenchView.title(q.section)).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
            Text(q.text).font(.mtBodyMedium)
            HStack {
                TextField("Your answer", text: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button("Add") { sidecar.answer(q, text: answers[q.id] ?? "", in: workbench); answers[q.id] = nil }
                    .disabled((answers[q.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                Button { sidecar.dismiss(questionID: q.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
    }

    private func findingCard(_ f: SidecarFinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BriefWorkbenchView.title(f.section)).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
            Text(f.issue).font(.mtBodyMedium)
            if let add = f.addition { Text("+ \(add)").font(.mtBodySmall).foregroundStyle(Color.mtPrimary) }
            HStack {
                if f.addition != nil { Button("Add this") { sidecar.accept(f, in: workbench) } }
                Button("Dismiss") { sidecar.dismiss(findingID: f.id) }
            }
        }
    }
}
#endif
