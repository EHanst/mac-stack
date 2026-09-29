#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Settings card: how much cloud you've used this month, an optional limit, and what left this Mac.
struct CloudUsageCard: View {
    @Environment(AppServices.self) private var services
    @State private var showAll = false

    private var usage: CloudUsageModel { services.cloudUsage }
    private static let presets: [(String, Int?)] = [
        ("No limit", nil), ("100 thousand", 100_000), ("500 thousand", 500_000),
        ("1 million", 1_000_000), ("5 million", 5_000_000),
    ]

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Cloud use & privacy log", systemImage: "cloud")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                limitRow
                MTDivider()
                ledger
            }
        }
        .task { await usage.reload() }
        .onChange(of: services.routingPolicy) { Task { await usage.reload() } }
    }

    private var limitRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Used this month").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                    Text(usage.tokensThisMonth.formatted() + " tokens" + (usage.monthlyTokenCap.map { " of \($0.formatted())" } ?? ""))
                        .font(.mtBodyMedium).foregroundStyle(Color.mtOnSurface)
                }
                Spacer()
                Picker("Monthly limit", selection: Binding(
                    get: { usage.monthlyTokenCap },
                    set: { cap in Task { await usage.setCap(cap) } })
                ) {
                    ForEach(Self.presets, id: \.0) { Text($0.0).tag($0.1) }
                    if let cap = usage.monthlyTokenCap, !Self.presets.contains(where: { $0.1 == cap }) {
                        Text("\(cap.formatted())").tag(Optional(cap))
                    }
                }
                .fixedSize()
            }
            if let cap = usage.monthlyTokenCap {
                ProgressView(value: min(1, Double(usage.tokensThisMonth) / Double(cap)))
            }
            Text("Counts only what cloud models process (prompt and answer, estimated when the provider doesn't say). When the limit is reached cloud requests stop until next month; your local model keeps working.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What left this Mac").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                Spacer()
                if !usage.entries.isEmpty { Button("Clear") { Task { await usage.clearLedger() } } }
            }
            if usage.entries.isEmpty {
                Text("Nothing has left this Mac.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            ForEach(showAll ? usage.entries : Array(usage.entries.prefix(6))) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: entry.blocked ? "hand.raised.fill" : "arrow.up.right")
                        .foregroundStyle(entry.blocked ? Color.mtDegraded : Color.mtOnSurfaceVariant)
                        .frame(width: 16)
                    Text(CloudUsageModel.describe(entry)).font(.mtBodySmall).foregroundStyle(Color.mtOnSurface)
                    Spacer()
                    Text(entry.date.formatted(.relative(presentation: .named)))
                        .font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
            if usage.entries.count > 6 {
                Button(showAll ? "Show fewer" : "Show all \(usage.entries.count)") { showAll.toggle() }
                    .buttonStyle(.link)
            }
            Text("Only the address and the kind of request are recorded — never what you asked or what was answered.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }
}
#endif
