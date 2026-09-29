#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Quick access to saved prompts from the chat box: search, pick, insert.
struct PromptPaletteView: View {
    let studio: PromptStudioModel
    let canSave: Bool
    let onPick: (SavedPrompt) -> Void
    let onPickProject: (WorkspacePromptStore.Entry) -> Void
    let onSaveCurrent: () -> Void
    let onManage: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search prompts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = results.first { onPick(first) } }
                .padding(10)
            MTDivider()
            let fromProjects = studio.projectPrompts.filter { entry in
                let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
                let hay = (entry.prompt.title + " " + entry.prompt.body + " " + entry.workspace).lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            if results.isEmpty {
                Text(studio.prompts.isEmpty ? "No saved prompts yet." : "Nothing matches.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { prompt in
                            Button { onPick(prompt) } label: { row(prompt) }.buttonStyle(.plain)
                        }
                        if !fromProjects.isEmpty {
                            Text("From your projects").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                                .padding(.horizontal, 12).padding(.top, 8)
                            ForEach(fromProjects) { entry in
                                Button { onPickProject(entry) } label: {
                                    HStack {
                                        row(entry.prompt)
                                        if !entry.approved {
                                            Text("Review").font(.mtLabelSmall).padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.mtTertiaryContainer).clipShape(Capsule())
                                                .padding(.trailing, 10)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            MTDivider()
            HStack {
                Button { onSaveCurrent() } label: { Label("Save what I typed", systemImage: "bookmark") }
                    .disabled(!canSave)
                Spacer()
                Button("Manage…") { onManage() }
            }
            .buttonStyle(MTTextButtonStyle())
            .padding(8)
        }
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private var results: [SavedPrompt] { studio.search(query) }

    private func row(_ p: SavedPrompt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: p.pinned ? "pin.fill" : "text.quote")
                .font(.system(size: 12)).foregroundStyle(Color.mtPrimary).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface).lineLimit(1)
                    if let slash = p.slash {
                        Text("/\(slash)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                    }
                }
                Text(p.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
#endif
