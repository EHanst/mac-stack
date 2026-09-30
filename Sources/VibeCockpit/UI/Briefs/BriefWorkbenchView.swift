#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Center column: pick a brief, edit its sections. The compiled prompt is on the right.
struct BriefWorkbenchView: View {
    @Environment(AppServices.self) private var services
    @State private var newTitle = ""
    @State private var creating = false
    @State private var improving = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(spacing: 0) {
            header
            MTDivider()
            if let brief = model.selected {
                editor(brief)
            } else {
                emptyState
            }
        }
        .background(Color.mtSurface)
        .sheet(isPresented: $improving) { improveSheet }
        .task { await model.reload() }
        .onDisappear { Task { await model.flush() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Brief", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.briefs) { Text($0.title).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .disabled(model.briefs.isEmpty)
            Spacer()
            Button { creating = true } label: { Label("New brief", systemImage: "plus") }
                .buttonStyle(MTFilledButtonStyle())
            Button(role: .destructive) { Task { await model.deleteSelected() } } label: { Image(systemName: "trash") }
                .disabled(model.selected == nil)
                .help("Delete this brief")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .alert("New brief", isPresented: $creating) {
            TextField("What is it for?", text: $newTitle)
            Button("Create") { let t = newTitle; newTitle = ""; Task { await model.newBrief(title: t) } }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 40)).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
            Text("No briefs yet").font(.mtTitleMedium)
            Text("A brief is the prompt you will hand to Claude Code, Cursor or ChatGPT. Start one and shape it here.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            Button("New brief") { creating = true }.buttonStyle(MTFilledButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editor(_ brief: Brief) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(BriefSection.Kind.allCases, id: \.self) { kind in
                    sectionEditor(kind, section: brief.sections.first { $0.kind == kind })
                }
            }
            .padding(16)
        }
    }

    private func sectionEditor(_ kind: BriefSection.Kind, section: BriefSection?) -> some View {
        let enabled = section?.enabled ?? true
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.title(kind)).font(.mtLabelLarge)
                Text("~\(PromptTokens.estimate(section?.text ?? "")) tokens")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                if kind == .goal {
                    Button("Improve") { improveGoal() }
                        .disabled((section?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                Toggle("Include", isOn: Binding(get: { enabled }, set: { model.setEnabled($0, for: kind) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            TextEditor(text: Binding(get: { section?.text ?? "" }, set: { model.setText($0, for: kind) }))
                .font(.mtBodyMedium)
                .frame(minHeight: kind == .goal ? 110 : 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .opacity(enabled ? 1 : 0.5)
            Text(Self.hint(kind)).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private var goalText: String { model.selected?.text(of: .goal) ?? "" }

    private func improveGoal() {
        services.promptStudio.startOptimize(draft: goalText, mode: .improve, intent: PromptEngineer.Intent.general.rawValue)
        improving = true
    }

    private var improveSheet: some View {
        OptimizeReviewSheet(
            studio: services.promptStudio, draft: goalText,
            onAccept: { model.setText($0, for: .goal); services.promptStudio.dismissReview(); improving = false },
            onExpand: { services.promptStudio.startOptimize(draft: goalText, mode: .expand, intent: PromptEngineer.Intent.general.rawValue) },
            onAskQuestions: { questions in
                model.setText(goalText + "\n\n" + questions.map { "Q: \($0)\nA: " }.joined(separator: "\n"), for: .goal)
                services.promptStudio.dismissReview(); improving = false
            },
            onClose: { services.promptStudio.dismissReview(); improving = false })
    }

    static func title(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "Goal"
        case .context: "Context"
        case .constraints: "Constraints"
        case .examples: "Examples"
        case .outputFormat: "Output format"
        }
    }

    static func hint(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "What you want done, in your own words."
        case .context: "Background the model cannot see on its own."
        case .constraints: "Rules it must follow, one per line."
        case .examples: "A sample of what good looks like."
        case .outputFormat: "How the answer should be shaped."
        }
    }
}
#endif
