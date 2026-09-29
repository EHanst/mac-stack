#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// "Run the AI on this Mac": what will be downloaded, one button, honest progress.
struct LocalSetupView: View {
    let setup: SetupModel
    let onChooseCloud: () -> Void

    private var plan: SetupPlan { setup.plan }
    private var chat: ModelCatalogEntry { ModelCatalog.bonsai27B }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.headline).font(.mtTitleLarge).foregroundStyle(Color.mtOnSurface)
                Text(plan.detail).font(.mtBodyMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                infoRow("desktopcomputer", setup.hardwareLine)
                if plan.downloadBytes > 0 {
                    infoRow("arrow.down.circle",
                            String(format: "%.1f GB download, about %d min at 100 Mbps",
                                   Double(plan.downloadBytes) / 1_000_000_000, plan.estimatedMinutes()))
                }
                if let context = setup.contextDescription {
                    infoRow("text.alignleft", "Holds a conversation of \(context) on this Mac")
                }
                infoRow("lock.shield", "Works offline. Your code never leaves this Mac.")
            }

            phaseView

            attribution

            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Button("Use a cloud provider instead", action: onChooseCloud)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.mtPrimary)
                    .disabled(setup.isInstalling)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Already have a model on disk?")
                            .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                        LocalModelPickerView()
                    }
                    .padding(.top, 8)
                }
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .disabled(setup.isInstalling)
            }
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        if let blocker = plan.blocker, setup.phase == .ready {
            Label(blocker, systemImage: "externaldrive.badge.exclamationmark")
                .font(.mtBodySmall).foregroundStyle(Color.mtError)
                .padding(10).background(Color.mtErrorContainer).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        switch setup.phase {
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Button(plan.downloads.isEmpty ? "Finish setup" : "Set up on this Mac") { setup.start() }
                    .buttonStyle(MTFilledButtonStyle())
                    .disabled(plan.blocker != nil)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if !setup.statusLine.isEmpty {
                    Text(setup.statusLine).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
        case .installing:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: setup.fraction)
                HStack {
                    Text(setup.statusLine).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    Spacer()
                    Button("Pause") { setup.cancel() }.buttonStyle(MTOutlinedButtonStyle())
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.mtBodySmall).foregroundStyle(Color.mtError)
                    .padding(10).background(Color.mtErrorContainer).clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Try again") { setup.start() }
                    .buttonStyle(MTFilledButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .finished:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.mtTitleSmall).foregroundStyle(Color.mtHealthy)
        }
    }

    private var attribution: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let credit = chat.attribution {
                Text(credit).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text("\(chat.displayName) is licensed under").font(.mtBodySmall)
                Link(chat.licenseName, destination: chat.licenseURL).font(.mtBodySmall)
            }
            .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.8))
        }
    }

    private func infoRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(Color.mtPrimary)
            Text(text).font(.mtBodyMedium).foregroundStyle(Color.mtOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
