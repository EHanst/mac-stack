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

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            MTDivider()
            historyList
            MTDivider()
            inputBar
        }
        .background(Color.mtSurface)
    }

    // MARK: Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.mtPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text("VibeCockpit")
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
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(coordinator.state.intentHistory) { event in
                        IntentEventBubble(event: event)
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Describe what you want to build…", text: $intentText, axis: .vertical)
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
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(inputFocused ? Color.mtPrimary : Color.mtOutline, lineWidth: inputFocused ? 2 : 1)
                )

            Button(action: submitIntent) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(MTIconButtonStyle(variant: .filled))
            .disabled(
                intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || coordinator.state.isGenerating
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.mtSurface)
    }

    private func submitIntent() {
        let trimmed = intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coordinator.state.isGenerating else { return }
        coordinator.send(.submitIntent(trimmed))
        intentText = ""
        Task { await services.processIntent(trimmed, coordinator: coordinator) }
    }
}

// MARK: - Intent event bubble

private struct IntentEventBubble: View {
    let event: IntentEvent

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
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.mtPrimary)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                    bottomTrailingRadius: 4, topTrailingRadius: 18
                )
            )
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
            Circle()
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
            Text(event.content)
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
            Label(event.content, systemImage: "cloud")
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
        case .notice:         "cloud"
        }
    }

    private var iconBackground: Color {
        switch event.kind {
        case .userPrompt:     Color.mtPrimary
        case .assistantToken: Color.mtPrimaryContainer
        case .toolCall:       Color.mtTertiaryContainer
        case .toolResult:     Color(red: 0.78, green: 0.95, blue: 0.82)
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
