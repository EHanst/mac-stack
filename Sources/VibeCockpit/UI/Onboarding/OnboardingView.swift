#if canImport(AppKit)
import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selection: OnboardingPath = .localModel

    enum OnboardingPath { case localModel, remoteAPI }

    var body: some View {
        ZStack {
            Color.mtSurfaceContainerLowest.ignoresSafeArea()
            VStack(spacing: 32) {
                header
                Picker("Setup method", selection: $selection) {
                    Text("Local Model").tag(OnboardingPath.localModel)
                    Text("Remote API").tag(OnboardingPath.remoteAPI)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                MTCard(elevation: 2, padding: 24) {
                    Group {
                        switch selection {
                        case .localModel:
                            LocalModelPickerView()
                        case .remoteAPI:
                            CredentialEntryView()
                        }
                    }
                    .frame(maxWidth: 440)
                }
                .frame(maxWidth: 480)
            }
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.mtPrimaryContainer)
                    .frame(width: 80, height: 80)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.mtOnPrimaryContainer)
            }
            Text("Welcome to VibeCockpit")
                .font(.mtHeadlineMedium)
                .foregroundStyle(Color.mtOnSurface)
            Text("Connect a model to start building.")
                .font(.mtBodyLarge)
                .foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }
}
#endif
