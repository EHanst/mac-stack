#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import AppKit
import SwiftUI

/// Settings card: let other apps on this Mac use the model, and decide which ones.
struct SharingCard: View {
    @Environment(AppServices.self) private var services
    @State private var newName = ""
    @State private var copied: String?

    private var sharing: APISharingModel { services.sharing }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Share with other apps", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.mtTitleSmall)
                    .foregroundStyle(Color.mtOnSurface)
                MTDivider()
                toggleRow
                if case .running = sharing.status { addressRow }
                if let error = sharing.loadError {
                    Text(error).font(.mtBodySmall).foregroundStyle(Color.mtDegraded)
                }
                if let token = sharing.newToken { tokenBanner(token) }
                if sharing.isEnabled || !sharing.clients.isEmpty {
                    MTDivider()
                    appsList
                }
            }
        }
    }

    // MARK: Switch

    private var toggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Let other apps on this Mac use my models", isOn: Binding(
                get: { sharing.isEnabled },
                set: { on in Task { await sharing.setEnabled(on) } }))
            Group {
                switch sharing.status {
                case .off:
                    Text("Off. Nothing outside VibeCockpit can reach your models. Turn it on to give tools like Cursor or scripts an OpenAI-compatible address on this Mac.")
                case .starting:
                    Text("Starting…")
                case .running:
                    Text("On. Only this Mac can connect, and only apps you add below.")
                case .failed(let message):
                    Text(message).foregroundStyle(Color.mtDegraded)
                }
            }
            .font(.mtBodySmall)
            .foregroundStyle(Color.mtOnSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addressRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Address").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
                Text(sharing.baseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Spacer()
            copyButton(sharing.baseURL, id: "url")
        }
    }

    // MARK: Apps

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apps allowed to connect").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
            if sharing.clients.isEmpty {
                Text("None yet. Add an app to get a key for it.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            ForEach(sharing.clients) { client in clientRow(client) }
            HStack {
                TextField("App name, e.g. Cursor", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add app", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let name = newName
        Task {
            if await sharing.createClient(name: name) { newName = "" }
        }
    }

    private func clientRow(_ client: APIClient) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.mtBodyMedium).foregroundStyle(client.isActive ? Color.mtOnSurface : Color.mtOnSurfaceVariant)
                Text(subtitle(for: client)).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
            if client.isActive {
                Menu("Permissions") {
                    ForEach(ClientScope.allCases, id: \.self) { scope in
                        Toggle(scope.title, isOn: Binding(
                            get: { client.scopes.contains(scope) },
                            set: { on in Task { await sharing.setScope(scope, enabled: on, for: client) } }))
                    }
                }
                .fixedSize()
                Button("Remove", role: .destructive) { Task { await sharing.revoke(client) } }
            } else {
                MTStatusBadge(label: "Removed", color: .mtUnavailable)
            }
        }
    }

    private func subtitle(for client: APIClient) -> String {
        let used = client.lastUsedAt.map { "last used " + $0.formatted(.relative(presentation: .named)) } ?? "never used"
        return "\(client.tokenPrefix)…  ·  \(used)"
    }

    // MARK: Token (shown once)

    private func tokenBanner(_ token: APISharingModel.NewToken) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key for \(token.clientName)").font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface)
            Text("Copy it now — for your safety it can't be shown again. If you lose it, remove the app and add it again.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(token.token).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                copyButton(token.token, id: "token")
                Button("Done") { sharing.dismissNewToken() }
            }
        }
        .padding(12)
        .background(Color.mtSurfaceContainerLowest, in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyButton(_ text: String, id: String) -> some View {
        Button(copied == id ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = id
            Task { try? await Task.sleep(for: .seconds(2)); if copied == id { copied = nil } }
        }
    }
}
#endif
