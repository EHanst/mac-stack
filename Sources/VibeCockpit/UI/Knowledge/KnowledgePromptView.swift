#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI

/// Sits under the workbench header: the first-run card, the later nudge, or the "N briefs learned" chip.
struct KnowledgePromptView: View {
    @Environment(AppServices.self) private var services
    private var model: KnowledgeModel { services.knowledge }

    var body: some View {
        Group {
            switch model.prompt {
            case .card: card
            case .nudge: nudge
            case nil: chip
            }
        }
        .task { await model.refresh() }
    }

    private var card: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 10) {
                MTCardTitle("Help \(AppBrand.name) learn from your accepted briefs", icon: "sparkles", tint: .accent)
                Text("When you save, copy or export a brief, \(AppBrand.name) can keep its text, with secrets removed, and use it as an example for future suggestions. It stays on this Mac, never includes your attached files, and you can turn it off or wipe it at any time.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Turn on") { Task { await model.turnOn() } }.buttonStyle(MTFilledButtonStyle())
                    Button("Not now") { model.dismissCard() }.buttonStyle(MTOutlinedButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var nudge: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.mtPrimary)
            Text("Learn from briefs like this one? Suggestions improve as you accept more.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurface)
            Spacer()
            Button("Turn on") { Task { await model.turnOn() } }.buttonStyle(MTFilledButtonStyle())
            Button("Not now") { model.dismissNudge() }.buttonStyle(MTOutlinedButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var chip: some View {
        if model.decision == .enabled {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color.mtPrimary)
                Text(model.learnedCount == 1 ? "1 brief learned" : "\(model.learnedCount) briefs learned")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
    }
}
#endif
