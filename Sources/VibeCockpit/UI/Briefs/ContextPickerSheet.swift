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
    private enum Readiness { case starting, noProject, ready }

    @State private var tab = Tab.search
    @State private var query = ""
    @State private var results: [ContextItem] = []
    @State private var searched = false
    @State private var message: String?
    @State private var readiness = Readiness.starting
    @State private var searchTask: Task<Void, Never>?
    @State private var busy = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add context").font(.mtTitleMedium)
                Spacer()
                Button("Done", action: onClose).buttonStyle(MTFilledButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().disabled(readiness != .ready)
            switch readiness {
            case .starting:
                note("Getting your projects ready. Try again in a moment.")
            case .noProject:
                note("Add a project in Settings first.")
            case .ready:
                switch tab {
                case .search: searchTab
                case .file: fileTab
                case .changes: changesTab
                }
            }
            if let message { note(message) }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .task { await refreshReadiness() }
        .onChange(of: tab) { _, _ in message = nil }
        .onDisappear { searchTask?.cancel() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
    }

    private func refreshReadiness() async {
        guard let source = model.contextSource else { readiness = .starting; return }
        readiness = (await source.roots()).isEmpty ? .noProject : .ready
    }

    private var searchTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search your code, e.g. login timeout", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
            if searched && results.isEmpty && message == nil {
                note("Nothing found. The project may still be indexing.")
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

    /// A newer search replaces an older one, so a slow earlier answer cannot overwrite fresher results.
    private func runSearch() {
        searchTask?.cancel()
        let asked = query
        searchTask = Task {
            do {
                let found = try await model.searchContext(asked)
                guard !Task.isCancelled else { return }
                results = found; searched = true; message = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []; searched = true; message = error.localizedDescription
            }
        }
    }

    private var fileTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("Pick a text file from one of your projects.")
            Button("Choose file…") { chooseFile() }.disabled(busy)
        }
    }

    private var changesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("Adds your uncommitted changes to tracked files, so the model sees the work in progress.")
            Button(busy ? "Reading changes…" : "Add working changes") {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await model.addWorkingDiff(); message = "Added." } catch { message = error.localizedDescription }
                }
            }
            .disabled(busy)
        }
    }

    private func chooseFile() {
        Task {
            let roots = await model.contextSource?.roots() ?? []
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            panel.directoryURL = roots.first
            // Attached to the sheet's window instead of a nested modal loop.
            let urls: [URL] = await withCheckedContinuation { cont in
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { cont.resume(returning: $0 == .OK ? panel.urls : []) }
                } else {
                    panel.begin { cont.resume(returning: $0 == .OK ? panel.urls : []) }
                }
            }
            var failures: [String] = []
            for url in urls {
                do { try await model.addFile(url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !urls.isEmpty { message = failures.isEmpty ? "Added." : failures.joined(separator: " · ") }
        }
    }
}
#endif
