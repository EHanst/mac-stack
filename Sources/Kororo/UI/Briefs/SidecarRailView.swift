#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
import StackCore
#endif
import SwiftUI

/// Paste reply button and the revision cards it produces, for the selected brief.
struct SidecarRailView: View {
    @Environment(AppServices.self) private var services
    @State private var showReply = false

    private var sidecar: BriefSidecarModel { services.sidecar }
    private var workbench: BriefWorkbenchModel { services.briefs }
    private func running(_ brief: Brief) -> Bool {
        if case .running(.revise) = sidecar.phase { sidecar.briefID == brief.id } else { false }
    }

    var body: some View {
        if let brief = workbench.selected { content(brief) }
    }

    private func content(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { showReply = true } label: { Label("Fix brief from AI's answer", systemImage: "arrowshape.turn.up.left") }
                    .disabled(running(brief))
                    .help("Paste what the AI answered and get suggested edits to this brief")
                if running(brief) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { sidecar.cancel() }
                }
                Spacer()
            }
            Text("Got a wrong or off-target answer? Paste it and get suggested edits to the brief.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            if sidecar.briefID == brief.id, case .failed(let message) = sidecar.phase {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
            if sidecar.briefID == brief.id, let result = sidecar.result {
                if let note = result.note { Text(note).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant) }
                ForEach(result.revisions) { revisionCard($0, briefID: brief.id) }
            }
        }
        .padding(12)
        .background(Color.mtSurfaceContainerHighest.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .sheet(isPresented: $showReply) {
            ReplySheet(title: "Fix brief from AI's answer",
                       prompt: "Paste the answer from Claude Code or ChatGPT. The sidecar suggests changes to this brief; nothing changes until you apply one.",
                       action: "Suggest changes",
                       onSubmit: { sidecar.run(.revise, brief: brief, reply: $0) },
                       onClose: { showReply = false })
        }
    }

    private func revisionCard(_ r: SidecarRevision, briefID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BriefVersionsSheet.diffText(WordDiff.segments(from: r.original, to: r.proposed)).font(.mtBodyMedium)
            HStack {
                Button("Apply") { sidecar.acceptRevision(r, in: workbench) }
                Button("Dismiss") { sidecar.dismiss(revisionID: r.id) }
            }
        }
    }
}
#endif
