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

    private var sidecar: BriefSidecarModel { services.sidecar }
    private var workbench: BriefWorkbenchModel { services.briefs }
    private var running: Bool { if case .running = sidecar.phase { true } else { false } }

    var body: some View {
        if let brief = workbench.selected { content(brief) }
    }

    private func content(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { sidecar.run(.interview, brief: brief) } label: { Label("Ask me", systemImage: "questionmark.bubble") }
                    .disabled(running)
                Button { sidecar.run(.critique, brief: brief) } label: { Label("Critique", systemImage: "checklist") }
                    .disabled(running)
                if running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { sidecar.cancel() }
                }
                Spacer()
            }
            if case .failed(let message) = sidecar.phase {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
            if sidecar.briefID == brief.id, let result = sidecar.result {
                if let note = result.note { Text(note).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant) }
                ForEach(result.questions) { questionCard($0) }
                ForEach(result.findings) { findingCard($0) }
            }
        }
        .padding(12)
        .background(Color.mtSurfaceContainerHighest.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
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
