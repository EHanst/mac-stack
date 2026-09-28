#if canImport(AppKit)
import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selection: OnboardingPath = .localModel

    enum OnboardingPath { case localModel, remoteAPI }

    var body: some View {
        VStack(spacing: 24) {
            header
            Picker("Setup method", selection: $selection) {
                Text("Local Model").tag(OnboardingPath.localModel)
                Text("Remote API").tag(OnboardingPath.remoteAPI)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            Group {
                switch selection {
                case .localModel:
                    LocalModelPickerView()
                case .remoteAPI:
                    CredentialEntryView()
                }
            }
            .frame(maxWidth: 500)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 56))
                .foregroundStyle(.purple)
            Text("Welcome to VibeCockpit")
                .font(.largeTitle.bold())
            Text("Connect a model to get started.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
