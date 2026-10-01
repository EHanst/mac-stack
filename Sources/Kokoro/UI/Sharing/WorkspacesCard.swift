#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI
import AppKit

/// Settings card: the project folders other apps (and the model) may work in.
struct WorkspacesCard: View {
    @Environment(AppServices.self) private var services
    private var model: WorkspacesModel { services.workspacesModel }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MTCardTitle("Projects", icon: "folder", tint: .warning)
                    Spacer()
                    Button("Add project…") { pick() }.buttonStyle(MTOutlinedButtonStyle())
                }
                Text("Folders that connected apps can search, read, change and build in. Each project is kept separate: its own search index, its own file boundary. With more than one, apps say which project each request is for.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = model.lastError {
                    Text(err).font(.mtBodySmall).foregroundStyle(Color.mtError)
                }
                if model.rows.isEmpty {
                    Text("No projects yet.").font(.mtBodyMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                ForEach(model.rows) { row in
                    MTDivider()
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.record.name).font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface)
                            Text(row.record.path)
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                                .lineLimit(1).truncationMode(.middle)
                            Text(WorkspacesModel.statusText(row.status))
                                .font(.mtBodySmall)
                                .foregroundStyle({ if case .failed = row.status { Color.mtError } else { Color.mtOnSurfaceVariant } }())
                        }
                        Spacer()
                        Button("Remove") { Task { await model.remove(row.id) } }.buttonStyle(MTOutlinedButtonStyle())
                    }
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { Task { await model.add(url) } }
    }
}
#endif
