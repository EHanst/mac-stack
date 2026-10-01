#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
import StackCore
#endif
import SwiftUI
import AppKit

/// The whole Briefs screen: the finished brief fills the window, one input bar sits at the bottom,
/// and "Start over" in the top right clears the slate so the next thing typed starts a new brief.
struct BriefStudioView: View {
    @Environment(AppServices.self) private var services
    @State private var draft = ""
    @State private var continuing = false
    @State private var showFix = false
    @FocusState private var inputFocused: Bool

    private var model: BriefWorkbenchModel { services.briefs }

    /// Nothing written yet: the input bar creates the brief instead of editing one.
    private var fresh: Bool {
        guard let b = model.selected else { return true }
        return b.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (b.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            continuationStatus
            MTDivider()
            if !fresh {
                // Same place as the Improve workspace's strip, so suggestions never change position.
                CappedScroll(maxHeight: 150) { BrainstormBanner { question in
                    draft = "On “\(question)”: "
                    inputFocused = true
                } }
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            if fresh { welcome } else { BriefPane() }
            MTDivider()
            BriefInputBar(text: $draft, fresh: fresh, focused: $inputFocused)
        }
        .background(Color.mtSurfaceContainerLowest)
        .task { await model.reload(); inputFocused = true }
        .sheet(isPresented: $continuing) {
            ReplySheet(title: "Continue from a session",
                       prompt: "Paste a long session. The sidecar summarizes it into a new brief; the paste is not kept.",
                       action: "Make brief",
                       onSubmit: { services.sidecar.continueFromSession($0, in: model) },
                       onClose: { continuing = false })
        }
    }

    @ViewBuilder private var continuationStatus: some View {
        switch services.sidecar.continuationPhase {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing the session…").font(.mtBodySmall)
                Button("Cancel") { services.sidecar.cancelContinuation() }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
                Button { services.sidecar.cancelContinuation() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
        case .idle:
            EmptyView()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.briefs.prefix(15)) { brief in
                    Button(brief.isDraft ? "\(brief.title) (draft)" : brief.title) {
                        model.select(brief.id); services.sidecar.clear()
                    }
                }
                if model.briefs.isEmpty { Text("No briefs yet") }
                Divider()
                Menu("New from template") {
                    ForEach(BriefTemplate.allCases, id: \.self) { template in
                        Button(template.rawValue) {
                            Task {
                                await model.newBrief(title: template.rawValue, input: template.markdown)
                                services.sidecar.clear()
                            }
                        }
                    }
                }
                Button("New from clipboard") {
                    Task { _ = await model.newBrief(fromClipboard: NSPasteboard.general.string(forType: .string) ?? "") }
                }
                Button("New from a pasted session…") { continuing = true }
                Button("Delete this brief", role: .destructive) {
                    Task { await model.deleteSelected(); services.sidecar.clear() }
                }
                .disabled(model.selected == nil)
            } label: {
                Label(model.selected?.title ?? "Briefs", systemImage: "doc.text")
            }
            .menuStyle(.button)
            .fixedSize()

            Button { showFix = true } label: { Label("Fix from AI's answer", systemImage: "arrowshape.turn.up.left") }
                .disabled(model.selected == nil)
                .popover(isPresented: $showFix, arrowEdge: .bottom) {
                    ScrollView { SidecarRailView().padding(14) }.frame(width: 460, height: 340)
                }
            Spacer()
            Button { startOver() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                .help("Clear everything so what you type next starts a new brief")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.cursor").font(.system(size: 40))
                .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
            Text("Rough idea in, precise prompt out").font(.mtTitleMedium)
            Text("Describe the task as roughly as you like: the goal, the files, the constraints. \(AppBrand.name) rewrites it into a prompt a frontier model can act on, keeping every detail and marking what is missing. Then keep typing to refine it: “add acceptance criteria”, “make step 3 more specific”.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startOver() {
        services.feedback.cancel()
        services.sidecar.clear()
        draft = ""
        Task {
            await model.flushNow()
            model.select(nil)
            inputFocused = true
        }
    }
}

/// One field for both jobs: the first message becomes the brief, every later one is an instruction
/// that edits it in plain language.
struct BriefInputBar: View {
    @Environment(AppServices.self) private var services
    @Binding var text: String
    let fresh: Bool
    var focused: FocusState<Bool>.Binding
    @State private var showAttachments = false

    private var model: BriefWorkbenchModel { services.briefs }
    private var feedback: BriefFeedbackModel { services.feedback }
    private var editing: Bool { !fresh && feedback.phase == .editing }
    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Editing…").font(.mtBodySmall) }
            } else if case .failed(let message) = feedback.phase {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attach() } label: { Image(systemName: "paperclip").font(.system(size: 18)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                    .frame(height: 38)
                    .help("Attach files, diffs or snippets")
                    .popover(isPresented: $showAttachments, arrowEdge: .top) {
                        ScrollView { ContextListView().padding(14) }.frame(width: 460, height: 340)
                    }
                TextField(fresh ? "Describe the task, roughly…"
                                : "What to change, e.g. “clarify the acceptance criteria”",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.mtBodyMedium)
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(10)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .onSubmit { send() }
                if !fresh, let brief = model.selected {
                    Button("Undo") { feedback.undo(briefID: brief.id) }
                        .disabled(!feedback.canUndo(briefID: brief.id))
                }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(blank || editing ? Color.mtOnSurfaceVariant.opacity(0.4) : Color.mtPrimary)
                    .disabled(blank || editing)
                    .help(fresh ? "Create the brief" : "Apply this change to the brief")
            }
        }
        .padding(12)
        .background(Color.mtSurface)
    }

    private func attach() {
        if model.selected == nil {
            Task { await model.newBrief(title: ""); showAttachments = true }
        } else {
            showAttachments = true
        }
    }

    private func send() {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !editing else { return }
        if fresh {
            if model.selected != nil {
                model.setInput(instruction)
            } else {
                Task { _ = await model.newBrief(fromClipboard: instruction) }
            }
            services.sidecar.clear()
        } else if let brief = model.selected {
            feedback.send(instruction, brief: brief)
        }
        text = ""
    }
}
#endif
