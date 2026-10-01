#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
#endif
import SwiftUI

/// The items attached to a brief: what each costs, where it came from, and how it is sent.
struct ContextListView: View {
    @Environment(AppServices.self) private var services
    @State private var picking = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.selected?.contextItems ?? []) { item in row(item) }
            HStack {
                Button { picking = true } label: { Label("Add context…", systemImage: "plus.circle") }
                Spacer()
                let count = model.selected?.contextItems.count ?? 0
                if count > 0 {
                    Text("\(count) item\(count == 1 ? "" : "s"), about \(model.contextTokens.formatted()) tokens")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
        }
        .sheet(isPresented: $picking) { ContextPickerSheet(onClose: { picking = false }) }
    }

    private func row(_ item: ContextItem) -> some View {
        let warning = model.compiled?.warnings.first { $0.itemID == item.id }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle("Include", isOn: Binding(get: { item.included }, set: { model.setContextIncluded($0, id: item.id) }))
                    .toggleStyle(.checkbox).labelsHidden()
                Image(systemName: Self.icon(item.kind)).foregroundStyle(Color.mtOnSurfaceVariant)
                Text(item.ref).font(.mtBodyMedium).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("~\(item.tokens.formatted())").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                if item.kind != .gitDiff && item.kind != .snippet {
                    Picker("Mode", selection: Binding(get: { item.mode }, set: { model.setContextMode($0, id: item.id) })) {
                        Text("Inline").tag(ContextMode.inline)
                        Text("Path").tag(ContextMode.reference)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 100)
                }
                Button { model.removeContext(id: item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help("Remove")
            }
            if !item.provenance.isEmpty {
                Text(item.provenance).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            if let warning {
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
        }
        .opacity(item.included ? 1 : 0.5)
    }

    private static func icon(_ kind: ContextItem.Kind) -> String {
        switch kind {
        case .file: "doc"
        case .symbol: "curlybraces"
        case .gitDiff: "plusminus"
        case .snippet: "text.quote"
        }
    }
}
#endif
