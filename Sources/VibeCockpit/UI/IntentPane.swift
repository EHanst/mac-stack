#if canImport(AppKit)
import SwiftUI

struct IntentPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var intentText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyList
            inputBar
        }
        .background(.background)
        .navigationTitle("Intent")
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(coordinator.state.intentHistory) { event in
                        IntentEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: coordinator.state.intentHistory.count) { _, _ in
                if let last = coordinator.state.intentHistory.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("What do you want to build?", text: $intentText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.body)
                    .onSubmit { submitIntent() }
                submitButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        if coordinator.state.isGenerating {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 28, height: 28)
        } else {
            Button(action: submitIntent) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .animation(.easeInOut(duration: 0.15), value: intentText.isEmpty)
        }
    }

    private func submitIntent() {
        let trimmed = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coordinator.state.isGenerating else { return }
        coordinator.send(.submitIntent(trimmed))
        intentText = ""
        Task {
            await services.processIntent(trimmed, coordinator: coordinator)
        }
    }
}

private struct IntentEventRow: View {
    let event: IntentEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.subheadline)
                .frame(width: 16)
                .padding(.top, 1)
            Text(event.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(event.kind == .error ? Color.red : Color.primary)
                .font(event.kind == .toolCall ? .system(.caption, design: .monospaced) : .body)
        }
        .padding(event.kind == .toolCall ? 8 : 0)
        .background(
            event.kind == .toolCall
                ? Color(nsColor: .controlBackgroundColor).opacity(0.8)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var iconName: String {
        switch event.kind {
        case .userPrompt:     "person.circle.fill"
        case .assistantToken: "sparkles"
        case .toolCall:       "wrench.and.screwdriver.fill"
        case .error:          "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .userPrompt:     .accentColor
        case .assistantToken: .purple
        case .toolCall:       .orange
        case .error:          .red
        }
    }
}
#endif
