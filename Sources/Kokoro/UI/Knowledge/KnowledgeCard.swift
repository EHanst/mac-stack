#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
import StackCore
#endif
import SwiftUI

/// Settings section: the opt-in, what is stored, browse/disable/delete, and wipe.
struct KnowledgeCard: View {
    @Environment(AppServices.self) private var services
    @State private var confirmWipe = false
    private var model: KnowledgeModel { services.knowledge }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                MTCardTitle("Learning", icon: "sparkles", tint: .accent)
                Toggle("Learn from my accepted briefs", isOn: Binding(
                    get: { model.decision == .enabled },
                    set: { on in Task { on ? await model.turnOn() : await model.turnOff() } }))
                Text("Kept on this Mac only: the text of briefs you save, copy or export, with secrets removed. Attached files are never kept. Turning this off stops recording; what is already stored stays until you wipe it.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Text(notice).font(.mtBodySmall).foregroundStyle(Color.mtOnSurface).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { model.dismissNotice() }.buttonStyle(MTOutlinedButtonStyle())
                    }
                }
                if let err = model.error { Text(err).font(.mtBodySmall).foregroundStyle(Color.mtError) }
                HStack {
                    Text(summary).font(.mtBodySmall).foregroundStyle(Color.mtOnSurface)
                    Spacer()
                    Button("Wipe learned data…") { confirmWipe = true }
                        .buttonStyle(MTOutlinedButtonStyle())
                        .disabled(model.learnedCount == 0)
                }
                if !model.packs.isEmpty {
                    MTDivider()
                    ForEach(model.packs, id: \.info.id) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(p.info.name) · \(p.count)").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface)
                                Text("\(p.info.license). \(p.info.attribution)").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { p.enabled },
                                                     set: { on in Task { await model.setPackEnabled(on, pack: p.info.id) } }))
                                .labelsHidden()
                        }
                    }
                }
                if !model.entries.isEmpty {
                    MTDivider()
                    ForEach(model.entries.prefix(50)) { e in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.meta["intent"] ?? e.kind.rawValue).font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface).lineLimit(1)
                                Text(e.text).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant).lineLimit(2)
                            }
                            Spacer()
                            Button(e.enabled ? "Disable" : "Enable") { Task { await model.setEnabled(!e.enabled, id: e.id) } }
                                .buttonStyle(MTOutlinedButtonStyle())
                            Button("Delete") { Task { await model.delete(id: e.id) } }.buttonStyle(MTOutlinedButtonStyle())
                        }
                    }
                }
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("Wipe everything learned from your briefs?", isPresented: $confirmWipe) {
            Button("Wipe", role: .destructive) { Task { await model.wipeLearned() } }
        } message: { Text("Packs stay. This can't be undone.") }
    }

    private var summary: String {
        let n = model.learnedCount
        return n == 1 ? "1 brief learned" : "\(n) briefs learned"
    }
}
#endif
