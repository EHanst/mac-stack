#if canImport(AppKit)
import SwiftUI

struct IntentPane: View {
    @Environment(AppCoordinator.self) private var coordinator
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
            Button(action: submitIntent) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func submitIntent() {
        let trimmed = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coordinator.send(.submitIntent(trimmed))
        intentText = ""
    }
}

private struct IntentEventRow: View {
    let event: IntentEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.kind == .userPrompt ? "person.circle" : "sparkles")
                .foregroundStyle(event.kind == .userPrompt ? .blue : .purple)
            Text(event.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
