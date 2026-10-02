#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI
import AppKit

/// The whole Briefs screen: the finished brief fills the window, one input bar sits at the bottom,
/// and "Start over" in the top right clears the slate so the next thing typed starts a new brief.
struct BriefStudioView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var draft = ""
    @State private var continuing = false
    @State private var showBrainstorm = false
    @State private var loadError: String?
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
            if let loadError {
                HStack {
                    Text(loadError).font(.mtBodySmall).foregroundStyle(Color.mtError)
                    Button { self.loadError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }
            MTDivider()
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
            if !coordinator.state.showSidebar {
                Button {
                    withAnimation(Motion.quick) {
                        coordinator.send(.toggleSidebar)
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(MTIconButtonStyle(variant: .standard))
                .help("Show Sidebar (⌃⌘S)")
            }

            Menu {
                ForEach(model.briefs.prefix(15)) { brief in
                    Button(brief.isDraft ? "\(brief.title) (draft)" : brief.title) {
                        model.select(brief.id); services.sidecar.clear()
                    }
                }
                if model.briefs.isEmpty { Text("No briefs yet") }
                if !model.savedFiles.isEmpty {
                    Divider()
                    Section("Saved files") {
                        ForEach(model.savedFiles.prefix(15)) { file in
                            Button(file.title) { load(file.url) }
                        }
                    }
                }
                Divider()
                Button("Load from file…") { pickFileToLoad() }.hotkey(.loadFile)
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
            .task { await model.refreshSavedFiles() }
            .onHover { if $0 { Task { await model.refreshSavedFiles() } } }

            if !fresh {
                if let brief = model.selected {
                    Text(BriefPhase.of(brief).rawValue)
                        .font(.mtLabelSmall)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.mtSurfaceContainerHigh)
                        .clipShape(Capsule())
                }
                Button { showBrainstorm = true } label: {
                    HotkeyLabel(title: brainstormLabel, systemImage: "lightbulb", hotkey: .brainstorm)
                }
                .hotkey(.brainstorm)
                .popover(isPresented: $showBrainstorm, arrowEdge: .bottom) {
                    ScrollView {
                        BrainstormBanner { question in
                            showBrainstorm = false
                            draft = "On “\(question)”: "
                            inputFocused = true
                        }
                    }
                    .frame(width: 460, height: 300)
                }
                BrainstormAutoRefresh()
            }
            Spacer()
            Button { startOver() } label: { HotkeyLabel(title: "Start over", systemImage: "arrow.counterclockwise", hotkey: .startOver) }
                .hotkey(.startOver)
                .help("Clear everything so what you type next starts a new brief")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var brainstormCount: Int { services.feedback.questions.count + services.feedback.tips.count }

    private var brainstormLabel: String {
        let count = brainstormCount
        return count > 0 ? "Brainstorm (\(count))" : "Brainstorm"
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

    private func load(_ url: URL) {
        Task {
            if let error = await model.loadBrief(from: url) { loadError = error } else { services.sidecar.clear() }
            await model.refreshSavedFiles()
        }
    }

    private func pickFileToLoad() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "md"), .plainText].compactMap { $0 }
        panel.prompt = "Load"
        if let root = model.savedFiles.first?.url.deletingLastPathComponent() { panel.directoryURL = root }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
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
    private var improve: BriefImproveModel { services.improve }
    /// While Improve is open on this brief, the bar edits Improve's working revision instead.
    private var improving: Bool { improve.presentedBriefID != nil && improve.presentedBriefID == model.selected?.id }
    private var optimizerRunning: Bool {
        switch improve.optimizerPhase {
        case .running, .repairing: return true
        default: return false
        }
    }
    private var editing: Bool {
        improving ? improve.chatEditPhase == .editing || optimizerRunning : !fresh && feedback.phase == .editing
    }
    private var failure: String? {
        if improving { if case .failed(let m) = improve.chatEditPhase { return m } else { return nil } }
        if case .failed(let m) = feedback.phase { return m }
        return nil
    }
    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always present, so the field never moves when an edit starts or fails.
            Group {
                if editing && !optimizerRunning {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Editing…").font(.mtBodySmall) }
                } else if let failure {
                    Text(failure).font(.mtBodySmall).foregroundStyle(Color.mtError).lineLimit(2)
                } else {
                    Text(" ").font(.mtBodySmall)
                }
            }
            .frame(minHeight: 16, alignment: .leading)
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
                                : improving ? "Instruct this revision, e.g. “add acceptance criteria”"
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
                if improving {
                    Button { improve.undoEdit() } label: { Text("Undo") }
 .disabled(!improve.canUndoEdit)
                        .help("Undo your last instruction. The rewrite stays open.")
                } else if !fresh, let brief = model.selected {
                    Button { feedback.undo(briefID: brief.id) } label: { Text("Undo") }
                        .disabled(!feedback.canUndo(briefID: brief.id))
                }
                Button { send() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                        Text(Hotkey.send.glyph).font(.mtLabelSmall)
                    }
                }
                    .hotkey(.send)
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
        if improving {
            improve.applyEdit(instruction)
        } else if fresh {
            // The first message is improved right away; later ones edit the result.
            Task {
                if model.selected == nil {
                    guard await model.newBrief(fromClipboard: instruction) else { return }
                } else {
                    model.setInput(instruction)
                }
                if let brief = model.selected { improve.open(brief, studio: services.promptStudio) }
            }
            services.sidecar.clear()
        } else if let brief = model.selected {
            feedback.send(instruction, brief: brief)
        }
        text = ""
    }
}
#endif
