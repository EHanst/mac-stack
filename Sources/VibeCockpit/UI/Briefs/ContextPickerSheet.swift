#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import AppKit

/// Adds repo context to the selected brief: a search of the code index, a file, or uncommitted changes.
struct ContextPickerSheet: View {
    @Environment(AppServices.self) private var services
    let onClose: () -> Void

    private enum Tab: String, CaseIterable { case search = "Search", file = "File", changes = "Changes" }
    @State private var tab = Tab.search
    @State private var query = ""
    @State private var results: [ContextItem] = []
    @State private var searched = false
    @State private var message: String?
    @State private var hasProject = true

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add context").font(.mtTitleMedium)
                Spacer()
                Button("Done", action: onClose).buttonStyle(MTFilledButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().disabled(!hasProject)
            if !hasProject {
                Text("Add a project in Settings first.").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            } else {
                switch tab {
                case .search: searchTab
                case .file: fileTab
                case .changes: changesTab
                }
            }
            if let message {
                Text(message).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .task { hasProject = !(await model.contextSource?.roots() ?? []).isEmpty }
    }

    private var searchTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search your code, e.g. login timeout", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { results = await model.searchContext(query); searched = true; message = nil } }
            if searched && results.isEmpty {
                Text("Nothing found. The project may still be indexing.").font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.ref).font(.mtBodyMedium).lineLimit(1).truncationMode(.middle)
                                Text("~\(item.tokens.formatted()) tokens").font(.mtBodySmall)
                                    .foregroundStyle(Color.mtOnSurfaceVariant)
                            }
                            Spacer()
                            let added = model.selected?.contextItems.contains { $0.id == item.id } ?? false
                            Button(added ? "Added" : "Add") { model.addContext([item]) }.disabled(added)
                        }
                    }
                }
            }
            if results.count > 1 { Button("Add all") { model.addContext(results) } }
        }
    }

    private var fileTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a text file from one of your projects.").font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)
            Button("Choose file…") { chooseFile() }
        }
    }

    private var changesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adds your uncommitted changes to tracked files, so the model sees the work in progress.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            Button("Add working changes") {
                Task {
                    do { try await model.addWorkingDiff(); message = "Added." } catch { message = error.localizedDescription }
                }
            }
        }
    }

    private func chooseFile() {
        Task {
            let roots = await model.contextSource?.roots() ?? []
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            panel.directoryURL = roots.first
            guard panel.runModal() == .OK else { return }
            var failures: [String] = []
            for url in panel.urls {
                do { try await model.addFile(url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            message = failures.isEmpty ? "Added." : failures.joined(separator: "\n")
        }
    }
}
#endif
