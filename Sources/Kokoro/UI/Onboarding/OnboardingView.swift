#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

/// First run. One recommendation for this Mac, one button. Everything else is a step away.
struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var setup: SetupModel?
    @State private var showCloud = false

    var body: some View {
        ZStack {
            Color.mtSurfaceContainerLowest.ignoresSafeArea()
            VStack(spacing: 28) {
                header
                MTCard(elevation: 2, padding: 24) {
                    Group {
                        if let setup {
                            content(for: setup)
                        } else {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Checking this Mac…")
                                    .font(.mtBodyMedium)
                                    .foregroundStyle(Color.mtOnSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: 440)
                }
                .frame(maxWidth: 480)
            }
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { setup = await services.makeSetupModel(coordinator: coordinator) }
    }

    @ViewBuilder
    private func content(for setup: SetupModel) -> some View {
        if setup.plan.mode == .local && !showCloud {
            LocalSetupView(setup: setup, onChooseCloud: { showCloud = true })
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if setup.plan.mode == .cloudOnly {
                    Text(setup.plan.headline).font(.mtTitleLarge).foregroundStyle(Color.mtOnSurface)
                    Text(setup.plan.detail).font(.mtBodyMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                    Text(setup.hardwareLine).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.8))
                } else {
                    Button { showCloud = false } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.mtPrimary)
                }
                CredentialEntryView()
            }
        }
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
            Text("Welcome to \(AppBrand.name)")
                .font(.mtHeadlineMedium)
                .foregroundStyle(Color.mtOnSurface)
            Text("Rough ideas in, prompts a frontier model can act on out. Written on this Mac.")
                .font(.mtBodyLarge)
                .foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }
}
#endif
