#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import AppKit
import SwiftUI

/// Settings card: pick an app, copy the setup text, test the connection.
struct ConnectCard: View {
    @Environment(AppServices.self) private var services
    @State private var selected = "claude-desktop"
    @State private var copied = false
    @State private var results: [APISharingModel.CheckLine] = []
    @State private var checking = false

    private var sharing: APISharingModel { services.sharing }
    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibecockpit/mcp.sock").path
    }
    private var snippets: [ConnectSnippet] {
        // A key that was just created is filled in so the text works as pasted.
        ConnectSnippets.all(baseURL: sharing.baseURL, socketPath: socketPath, key: sharing.newToken?.token ?? "YOUR_KEY")
    }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                MTCardTitle("Connect an app", icon: "link", tint: .accent)
                MTDivider()
                if !sharing.isEnabled {
                    Text("Turn on sharing above first. Claude Desktop connects without it; Cursor, scripts and the OpenAI library need it.")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("App", selection: $selected) {
                    ForEach(snippets) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if let snippet = snippets.first(where: { $0.id == selected }) {
                    Text(snippet.instructions)
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(snippet.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.mtSurfaceContainerLowest, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet.text, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        }
                        Spacer()
                        Button(checking ? "Testing…" : "Test connection") {
                            checking = true
                            Task {
                                results = await sharing.runCheck(socketPath: socketPath)
                                checking = false
                            }
                        }
                        .disabled(checking)
                    }
                }
                ForEach(results) { line in
                    Label(line.text, systemImage: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.mtBodySmall)
                        .foregroundStyle(line.ok ? Color.mtHealthy : Color.mtDegraded)
                }
            }
        }
        .onChange(of: selected) { results = [] }
    }
}
#endif
