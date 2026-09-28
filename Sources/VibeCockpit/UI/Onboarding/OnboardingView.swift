#if canImport(AppKit)
import SwiftUI

struct OnboardingView: View {
    @State private var selection: OnboardingPath = .localModel

    enum OnboardingPath { case localModel, remoteAPI }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 52)
                .padding(.bottom, 36)

            GroupBox {
                VStack(spacing: 0) {
                    Picker("Setup method", selection: $selection) {
                        Label("Local Model", systemImage: "cpu")
                            .tag(OnboardingPath.localModel)
                        Label("Remote API", systemImage: "network")
                            .tag(OnboardingPath.remoteAPI)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(16)

                    Divider()

                    Group {
                        switch selection {
                        case .localModel:
                            LocalModelPickerView()
                        case .remoteAPI:
                            CredentialEntryView()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 460)
            .padding(.bottom, 48)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.purple.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            Text("VibeCockpit")
                .font(.largeTitle.bold())
            Text("Connect a model provider to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
