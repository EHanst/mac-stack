#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import UniformTypeIdentifiers

/// The Prompts page: everything saved, plus the per-task guidance ("recipes") the app adds to
/// your messages.
struct PromptLibraryView: View {
    @Environment(AppServices.self) private var services
    @State private var query = ""
    @State private var path: [String] = []
    @State private var message: String?

    private var studio: PromptStudioModel { services.promptStudio }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Your prompts") {
                    let found = studio.search(query)
                    if found.isEmpty {
                        Text(studio.prompts.isEmpty ? "Nothing saved yet. Save anything you type from the chat box." : "Nothing matches.")
                            .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    }
                    ForEach(found) { p in
                        NavigationLink(value: p.id) { row(p) }
                            .contextMenu {
                                Button(p.pinned ? "Unpin" : "Pin", systemImage: "pin") { Task { await studio.togglePinned(p) } }
                                Button("Export…", systemImage: "square.and.arrow.up") { export(p) }
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(p) }
                            }
                    }
                }
                Section {
                    ForEach(studio.recipes) { r in
                        NavigationLink(value: r.id) {
                            HStack {
                                Image(systemName: r.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(r.enabled ? Color.mtHealthy : Color.mtOnSurfaceVariant)
                                Text((r.recipeIntent ?? r.title).capitalized).font(.mtLabelLarge)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("Guidance added to your messages")
                } footer: {
                    Text("Each kind of request gets a few lines of guidance added before it is sent. Edit or switch them off here; “What the model sees” in the chat shows the result.")
                        .font(.mtBodySmall)
                }
            }
            .searchable(text: $query, prompt: "Search prompts")
            .navigationTitle("Prompts")
            .toolbar {
                ToolbarItemGroup {
                    Button { newPrompt() } label: { Label("New prompt", systemImage: "plus") }
                    Button { importFile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                }
            }
            .navigationDestination(for: String.self) { id in
                PromptEditorView(promptID: id) { path.removeAll() }
            }
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Label(message, systemImage: "info.circle").font(.mtBodySmall)
                        .padding(8).frame(maxWidth: .infinity).background(Color.mtSurfaceContainerHighest)
                }
            }
        }
        .task { await studio.reload() }
    }

    private func row(_ p: SavedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if p.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.mtPrimary) }
                Text(p.title).font(.mtLabelLarge).lineLimit(1)
                if let slash = p.slash {
                    Text("/\(slash)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                Spacer()
                if p.useCount > 0 { Text("used \(p.useCount)×").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant) }
            }
            Text(p.body.replacingOccurrences(of: "\n", with: " ")).font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant).lineLimit(1)
        }
    }

    private func newPrompt() {
        Task {
            if let saved = try? await studio.save(SavedPrompt(title: "New prompt", body: "")) { path = [saved.id] }
        }
    }

    private func delete(_ p: SavedPrompt) {
        Task {
            do { try await studio.delete(id: p.id) } catch { message = error.localizedDescription }
        }
    }

    private func export(_ p: SavedPrompt) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (p.slash ?? p.title) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PromptLibrary.exportMarkdown(p).write(to: url, atomically: true, encoding: .utf8); message = "Saved \(url.lastPathComponent)." }
        catch { message = error.localizedDescription }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            var imported = 0
            for url in panel.urls {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if (try? await studio.importMarkdown(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)) != nil { imported += 1 }
            }
            message = imported == 0 ? "Couldn't read those files." : "Imported \(imported) prompt\(imported == 1 ? "" : "s"). Imported text is only ever pasted into the chat box; you decide what to send."
        }
    }
}

// MARK: - Editor

struct PromptEditorView: View {
    @Environment(AppServices.self) private var services
    let promptID: String
    let onGone: () -> Void

    @State private var draft: SavedPrompt?
    @State private var tagsText = ""
    @State private var error: String?
    @State private var saved = false
    @State private var variantFamily = "local"

    private var studio: PromptStudioModel { services.promptStudio }
    private static let families: [(String, String)] = [
        ("local", "Model on this Mac"), ("claude", "Claude"), ("gpt", "GPT"), ("generic", "Other cloud"),
    ]

    var body: some View {
        Group {
            if let draft { form(draft) } else { ProgressView() }
        }
        .task {
            await studio.reload()
            if let p = (studio.prompts + studio.recipes).first(where: { $0.id == promptID }) {
                draft = p
                tagsText = p.tags.joined(separator: ", ")
            } else {
                onGone()
            }
        }
    }

    private func form(_ p: SavedPrompt) -> some View {
        let binding = Binding<SavedPrompt>(get: { draft ?? p }, set: { draft = $0; saved = false })
        return Form {
            if p.kind == .recipe {
                Section {
                    Toggle("Add this guidance to \((p.recipeIntent ?? "").capitalized) requests", isOn: binding.enabled)
                }
            } else {
                Section {
                    TextField("Title", text: binding.title)
                    TextField("Shortcut (type /name in the chat box)", text: Binding(
                        get: { binding.wrappedValue.slash ?? "" },
                        set: { var v = binding.wrappedValue; v.slash = SavedPrompt.cleanSlash($0); binding.wrappedValue = v }))
                    TextField("Tags, comma separated", text: $tagsText)
                        .onChange(of: tagsText) { _, new in
                            var v = binding.wrappedValue
                            v.tags = new.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            binding.wrappedValue = v
                        }
                    Toggle("Pin to the top", isOn: binding.pinned)
                }
            }
            Section("Text") {
                TextEditor(text: binding.body).font(.mtBodyMedium).frame(minHeight: 160)
                let blanks = PromptTemplate.variables(in: binding.wrappedValue.body)
                if !blanks.isEmpty {
                    Text("Blanks you'll be asked for: " + blanks.map { "{{\($0)}}" }.joined(separator: "  "))
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
            if p.kind == .prompt {
                Section("Different wording for a model") {
                    Picker("Model", selection: $variantFamily) {
                        ForEach(Self.families, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    TextEditor(text: Binding(
                        get: { binding.wrappedValue.modelVariants[variantFamily] ?? "" },
                        set: { var v = binding.wrappedValue; v.modelVariants[variantFamily] = $0.isEmpty ? nil : $0; binding.wrappedValue = v }))
                        .font(.mtBodyMedium).frame(minHeight: 80)
                    Text("Used instead of the text above when that kind of model is answering. Leave empty to use the same text everywhere.")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
            if !p.versions.isEmpty {
                Section("Earlier versions") {
                    ForEach(Array(p.versions.enumerated().reversed()), id: \.offset) { index, v in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.mtLabelMedium)
                                Text(v.body.replacingOccurrences(of: "\n", with: " ")).font(.mtBodySmall)
                                    .foregroundStyle(Color.mtOnSurfaceVariant).lineLimit(1)
                            }
                            Spacer()
                            Button("Restore") { restore(index) }
                        }
                    }
                }
            }
            Section {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.mtError) }
                HStack {
                    if p.builtIn { Button("Reset to default") { reset() } }
                    else { Button("Delete", role: .destructive) { delete() } }
                    Spacer()
                    if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(Color.mtHealthy) }
                    Button("Save") { save() }.keyboardShortcut("s", modifiers: .command).buttonStyle(MTFilledButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(p.kind == .recipe ? (p.recipeIntent ?? "").capitalized : p.title)
    }

    private func save() {
        guard let draft else { return }
        Task {
            do { self.draft = try await studio.save(draft); error = nil; saved = true }
            catch { self.error = error.localizedDescription }
        }
    }

    private func restore(_ index: Int) {
        Task {
            do {
                try await studio.restore(id: promptID, versionIndex: index)
                draft = (studio.prompts + studio.recipes).first { $0.id == promptID }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func reset() {
        Task {
            do {
                try await studio.resetToDefault(id: promptID)
                draft = (studio.prompts + studio.recipes).first { $0.id == promptID }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func delete() {
        Task {
            do { try await studio.delete(id: promptID); onGone() }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
