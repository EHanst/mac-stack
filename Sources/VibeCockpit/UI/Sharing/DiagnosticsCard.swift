#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import AppKit

/// Settings card: how recent replies went, why one was slow, and a support bundle that leaks nothing.
struct DiagnosticsCard: View {
    @Environment(AppServices.self) private var services
    @State private var expanded: UUID?
    private var model: DiagnosticsModel { services.diagnostics }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Speed & support", systemImage: "stethoscope")
                        .font(.mtTitleSmall).foregroundStyle(Color.mtOnSurface)
                    Spacer()
                    Button("Refresh") { Task { await model.reload() } }.buttonStyle(MTOutlinedButtonStyle())
                    Button("Export support bundle…") { export() }.buttonStyle(MTFilledButtonStyle())
                }
                Text("The support bundle lists your Mac, the models, timings and where requests went. It never includes your prompts, answers, files, keys or project paths, and nothing is sent anywhere: you choose where to save it and who gets it.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = model.exportError { Text(err).font(.mtBodySmall).foregroundStyle(Color.mtError) }
                if model.recent.isEmpty {
                    Text("No replies yet.").font(.mtBodyMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                ForEach(model.recent) { r in
                    MTDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.date.formatted(date: .omitted, time: .standard))
                                    .font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface)
                                Text(DiagnosticsModel.summary(r))
                                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                            }
                            Spacer()
                            Button(expanded == r.id ? "Hide" : "Why this speed?") {
                                expanded = expanded == r.id ? nil : r.id
                            }.buttonStyle(MTOutlinedButtonStyle())
                        }
                        if expanded == r.id {
                            ForEach(model.explanation(for: r), id: \.self) { line in
                                Text("• " + line).font(.mtBodySmall).foregroundStyle(Color.mtOnSurface)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .task { await model.reload() }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppBrand.name)-support-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportBundle(to: url) }
    }
}
#endif
