#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

struct IntentPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var intentText = ""
    @FocusState private var inputFocused: Bool
    @State private var intentOverride: PromptEngineer.Intent?
    @State private var sheet: ComposerSheet?
    @State private var showPalette = false
    /// Opens the Prompts page; set by the main layout.
    var onManagePrompts: () -> Void = {}

    private enum ComposerSheet: Identifiable {
        case improve, inspect
        case save(String)
        case insert(SavedPrompt)
        case reviewProject(WorkspacePromptStore.Entry)
        var id: String {
            switch self {
            case .improve: "improve"
            case .inspect: "inspect"
            case .save: "save"
            case .insert(let p): "insert-\(p.id)"
            case .reviewProject(let e): "review-\(e.id)"
            }
        }
    }

    private var studio: PromptStudioModel { services.promptStudio }
    private var draftIsEmpty: Bool { intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var activeIntent: PromptEngineer.Intent { intentOverride ?? PromptEngineer.classify(intentText) }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            MTDivider()
            historyList
            MTDivider()
            inputBar
        }
        .background(Color.mtSurface)
        .sheet(item: $sheet) { which in sheetContent(which) }
        .task { await studio.reload(); await studio.refreshModel() }
    }

    @ViewBuilder
    private func sheetContent(_ which: ComposerSheet) -> some View {
        switch which {
        case .improve:
            OptimizeReviewSheet(
                studio: studio, draft: intentText,
                onAccept: { text in intentText = text; sheet = nil },
                onExpand: { studio.startOptimize(draft: intentText, mode: .expand, intent: activeIntent.rawValue) },
                onAskQuestions: { questions in
                    intentText += "\n\n" + questions.map { "Q: \($0)\nA: " }.joined(separator: "\n")
                    studio.dismissReview()
                    sheet = nil
                },
                onClose: { sheet = nil })
        case .inspect:
            PromptInspectorSheet(
                draft: intentText, intent: intentOverride,
                onClose: { sheet = nil })
        case .save(let text):
            SavePromptSheet(studio: studio, initialBody: text) { sheet = nil }
        case .insert(let prompt):
            InsertPromptSheet(studio: studio, prompt: prompt,
                              onInsert: { text in place(text, from: prompt); sheet = nil },
                              onCancel: { sheet = nil })
        case .reviewProject(let entry):
            ReviewProjectPromptSheet(studio: studio, entry: entry,
                                     onApproved: { prompt in sheet = nil; beginInsert(prompt) },
                                     onCancel: { sheet = nil })
        }
    }

    // MARK: Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.mtPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppBrand.name)
                    .font(.mtTitleMedium)
                    .foregroundStyle(Color.mtOnSurface)
                generationStatus
            }
            Spacer()
            if coordinator.state.isGenerating {
                Button {
                    // future: cancel generation
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(MTIconButtonStyle(variant: .tonal))
                .help("Cancel generation")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var generationStatus: some View {
        Group {
            if coordinator.state.isGenerating {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                    Text("Generating…")
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtPrimary)
                }
            } else if let model = coordinator.state.providerHealth.first(where: { $0.value == .healthy })?.key {
                Text(model.hasPrefix("local:") ? String(model.dropFirst(6)) : model)
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtHealthy)
            } else {
                Text("No model ready")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
        }
    }

    // MARK: History

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if coordinator.state.intentHistory.isEmpty {
                    Text("Quick questions only. Build the real prompt in Briefs.")
                        .font(.mtBodySmall)
                        .foregroundStyle(Color.mtOnSurfaceVariant)
                        .padding(16)
                }
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(coordinator.state.intentHistory) { event in
                        IntentEventBubble(event: event, onSave: { sheet = .save($0) })
                            .id(event.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: coordinator.state.intentHistory.count) { _, _ in
                if let last = coordinator.state.intentHistory.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            slashSuggestions
            lintChips
            fieldRow
            toolRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.mtSurface)
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Describe the task you want a prompt for…", text: $intentText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.mtBodyMedium)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit {
                    guard !NSEvent.modifierFlags.contains(.shift) else { return }
                    submitIntent()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card)
                        .stroke(inputFocused ? Color.mtPrimary : Color.mtOutline, lineWidth: inputFocused ? 2 : 1)
                )

            Button(action: submitIntent) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(MTIconButtonStyle(variant: .filled))
            .disabled(draftIsEmpty || coordinator.state.isGenerating)
        }
    }

    // MARK: Prompt tools

    /// `/name` in the box lists saved prompts with that shortcut.
    @ViewBuilder
    private var slashSuggestions: some View {
        if intentText.hasPrefix("/"), !intentText.contains(" "), !intentText.contains("\n") {
            let matches = studio.slashMatches(String(intentText.dropFirst()))
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.prefix(5)) { p in
                        Button { beginInsert(p) } label: {
                            HStack {
                                Text("/\(p.slash ?? "")")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color.mtPrimary)
                                Text(p.title).font(.mtBodySmall).foregroundStyle(Color.mtOnSurface)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// Instant hints about the draft; a chip with a suggestion adds it to the box when clicked.
    @ViewBuilder
    private var lintChips: some View {
        let findings = studio.lint(intentText, intent: activeIntent.rawValue)
        if !findings.isEmpty, !studio.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(findings.prefix(2)) { f in
                    Button {
                        if let s = f.suggestion { intentText += s; inputFocused = true }
                    } label: {
                        Label(f.message, systemImage: f.suggestion == nil ? "lightbulb" : "plus.circle")
                            .font(.mtBodySmall)
                            .foregroundStyle(Color.mtOnTertiaryContainer)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.mtTertiaryContainer.opacity(0.7))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(f.suggestion == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Full labels when they fit; icons only (and a shorter token count) when the pane is narrow.
    private var toolRow: some View {
        ViewThatFits(in: .horizontal) {
            toolRowContent(compact: false)
            toolRowContent(compact: true)
        }
    }

    private func toolRowContent(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("Improve") { improve(.improve) }
                Menu("Expand with detail") {
                    Button("Concise") { improve(.expand, depth: .concise) }
                    Button("Standard") { improve(.expand, depth: .standard) }
                    Button("Exhaustive") { improve(.expand, depth: .exhaustive) }
                }
                Button("Adapt for \(studio.profile.displayName)") { improve(.adapt) }
            } label: {
                Label("Improve", systemImage: "wand.and.stars").lineLimit(1)
            } primaryAction: {
                improve(.improve)
            }
            .fixedSize()
            .disabled(draftIsEmpty || coordinator.state.isGenerating)
            .keyboardShortcut("o", modifiers: [.command, .option])
            .help("Rewrite your message so the model understands it better (⌥⌘O). You review it before anything is sent.")

            Button { showPalette = true } label: {
                Label("Prompts", systemImage: "text.book.closed").lineLimit(1)
                    .labelStyle(CompactLabelStyle(compact: compact))
            }
                .fixedSize()
                .help("Saved prompts")
                .popover(isPresented: $showPalette, arrowEdge: .top) {
                    PromptPaletteView(
                        studio: studio, canSave: !draftIsEmpty,
                        onPick: { showPalette = false; beginInsert($0) },
                        onPickProject: { showPalette = false; beginInsert(project: $0) },
                        onSaveCurrent: { showPalette = false; sheet = .save(intentText) },
                        onManage: { showPalette = false; onManagePrompts() })
                }

            if studio.undoDraft != nil {
                Button {
                    if let back = studio.takeUndo() { intentText = back }
                } label: {
                    Label("Undo improve", systemImage: "arrow.uturn.backward").lineLimit(1)
                        .labelStyle(CompactLabelStyle(compact: compact))
                }
                .fixedSize()
                .help("Put back what you wrote before Improve")
            }
            Spacer(minLength: 4)
            intentMenu
            if !draftIsEmpty {
                let tokens = PromptTokens.estimate(intentText)
                Text(compact ? "≈\(tokens.formatted())" : "≈\(tokens.formatted()) tokens")
                    .font(.mtLabelSmall)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(tokens > studio.profile.maxUsefulTokens ? Color.mtError : Color.mtOnSurfaceVariant)
                    .help("Rough size of what you typed. Guidance and project code are added on top; see “What the model sees”.")
            }
            Button { sheet = .inspect } label: { Image(systemName: "eye") }
                .help("What the model sees")
        }
        .buttonStyle(MTTextButtonStyle())
        .font(.mtLabelMedium)
        .padding(.horizontal, 4)
    }

    private struct CompactLabelStyle: LabelStyle {
        let compact: Bool
        func makeBody(configuration: Configuration) -> some View {
            if compact { configuration.icon } else { Label(configuration) }
        }
    }

    private var intentMenu: some View {
        Menu {
            Button("Automatic") { intentOverride = nil }
            Divider()
            ForEach(BuiltInPrompts.intents, id: \.self) { key in
                Button(key.capitalized) { intentOverride = PromptEngineer.Intent(rawValue: key) }
            }
        } label: {
            Label(draftIsEmpty ? "Task" : activeIntent.rawValue.capitalized + (intentOverride == nil ? "" : " •"),
                  systemImage: "tag")
        }
        .fixedSize()
        .help("What kind of request this is. It picks the guidance added to your message; edit that under Prompts.")
    }

    private func improve(_ mode: OptimizeMode, depth: OptimizeDepth? = nil) {
        guard !draftIsEmpty else { return }
        studio.startOptimize(draft: intentText, mode: mode, intent: activeIntent.rawValue, depth: depth)
        sheet = .improve
    }

    private func beginInsert(_ prompt: SavedPrompt) {
        if studio.fieldsToAsk(for: prompt).isEmpty {
            place(studio.text(for: prompt), from: prompt)
        } else {
            sheet = .insert(prompt)
        }
    }

    private func beginInsert(project entry: WorkspacePromptStore.Entry) {
        if entry.approved { beginInsert(entry.prompt) } else { sheet = .reviewProject(entry) }
    }

    private func place(_ text: String, from prompt: SavedPrompt) {
        intentText = text
        inputFocused = true
        Task { await studio.markUsed(prompt.id) }
    }

    private func submitIntent() {
        let trimmed = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coordinator.state.isGenerating else { return }
        // "/name" with a saved prompt of that name expands it instead of sending.
        if trimmed.hasPrefix("/"), !trimmed.contains(" "), !trimmed.contains("\n"),
           let match = studio.prompt(slash: trimmed) {
            beginInsert(match)
            return
        }
        let override = intentOverride
        coordinator.send(.submitIntent(trimmed))
        intentText = ""
        intentOverride = nil
        studio.clearUndo()
        Task { await services.processIntent(trimmed, coordinator: coordinator, intent: override) }
    }
}

// MARK: - Intent event bubble

private struct IntentEventBubble: View {
    @Environment(AppCoordinator.self) private var coordinator
    let event: IntentEvent
    var onSave: (String) -> Void = { _ in }

    /// True while this is the reply the model is still writing.
    private var isLive: Bool {
        coordinator.state.isGenerating && coordinator.state.intentHistory.last?.id == event.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if event.kind == .userPrompt {
                Spacer(minLength: 40)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 40)
            }
        }
        .padding(.vertical, 2)
    }

    private var userBubble: some View {
        Text(event.content)
            .font(.mtBodyMedium)
            .foregroundStyle(Color.mtOnPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.mtPrimary)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                    bottomTrailingRadius: 4, topTrailingRadius: 18
                )
            )
            .contextMenu {
                Button("Save as prompt…", systemImage: "bookmark") { onSave(event.content) }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(event.content, forType: .string)
                }
            }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            assistantIcon
            VStack(alignment: .leading, spacing: 4) {
                assistantContent
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var assistantIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control)
                .fill(iconBackground)
                .frame(width: 28, height: 28)
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(iconForeground)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var assistantContent: some View {
        switch event.kind {
        case .userPrompt:
            EmptyView()

        case .assistantToken:
            StreamRevealText(event.content, live: isLive)
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurface)

        case .toolCall:
            HStack(spacing: 6) {
                Text(event.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.mtOnTertiaryContainer)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.mtTertiaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .toolResult:
            Text(event.content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .lineLimit(6)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .notice:
            Label(event.content, systemImage: event.symbol ?? "cloud")
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .error:
            Label(event.content, systemImage: "exclamationmark.triangle.fill")
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtError)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.mtErrorContainer)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var iconName: String {
        switch event.kind {
        case .userPrompt:     "person.fill"
        case .assistantToken: "sparkles"
        case .toolCall:       "wrench.and.screwdriver.fill"
        case .toolResult:     "checkmark"
        case .error:          "exclamationmark.triangle.fill"
        case .notice:         event.symbol ?? "cloud"
        }
    }

    private var iconBackground: Color {
        switch event.kind {
        case .userPrompt:     Color.mtPrimary
        case .assistantToken: Color.mtPrimaryContainer
        case .toolCall:       Color.mtTertiaryContainer
        case .toolResult:     Palette.successFill
        case .error:          Color.mtErrorContainer
        case .notice:         Color.mtSurfaceContainerHighest
        }
    }

    private var iconForeground: Color {
        switch event.kind {
        case .userPrompt:     Color.mtOnPrimary
        case .assistantToken: Color.mtOnPrimaryContainer
        case .toolCall:       Color.mtOnTertiaryContainer
        case .toolResult:     Color.mtHealthy
        case .error:          Color.mtError
        case .notice:         Color.mtOnSurfaceVariant
        }
    }
}
#endif
