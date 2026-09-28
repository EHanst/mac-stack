#if canImport(AppKit)
import SwiftUI

struct IntentPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var intentText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyList
            Divider()
            inputBar
        }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.state.intentHistory) { event in
                        IntentEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: coordinator.state.intentHistory.count) { _, _ in
                if let last = coordinator.state.intentHistory.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Describe what you want to build…", text: $intentText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { submitIntent() }
            if coordinator.state.isGenerating {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 28, height: 28)
            } else {
                Button(action: submitIntent) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(event.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(event.kind == .error ? Color.red : Color.primary)
        }
    }

    private var iconName: String {
        switch event.kind {
        case .userPrompt:    "person.circle"
        case .assistantToken: "sparkles"
        case .toolCall:      "wrench.and.screwdriver"
        case .error:         "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .userPrompt:    .blue
        case .assistantToken: .purple
        case .toolCall:      .orange
        case .error:         .red
        }
    }
}
#endif
