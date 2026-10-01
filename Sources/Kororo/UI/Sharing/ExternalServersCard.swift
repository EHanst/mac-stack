#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
#endif
import SwiftUI

/// Settings card: other MCP servers whose tools the model may use.
struct ExternalServersCard: View {
    @Environment(AppServices.self) private var services
    @State private var adding = false
    @State private var name = ""
    @State private var command = ""
    @State private var arguments = ""

    private var model: ExternalServersModel { services.externalServersModel }

    var body: some View {
        MTCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MTCardTitle("Tools from other MCP servers", icon: "puzzlepiece.extension", tint: .accent)
                    Spacer()
                    Button(adding ? "Cancel" : "Add server") { adding.toggle() }
                        .buttonStyle(MTOutlinedButtonStyle())
                }
                Text("Lets the model use tools from programs that speak MCP (for example a GitHub or database server). Each server is a program that runs on this Mac. You'll be asked before every tool call, and anything a server returns is treated as untrusted.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if adding { form }
                if model.rows.isEmpty, !adding {
                    Text("No servers added.").font(.mtBodyMedium).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                ForEach(model.rows) { row in
                    MTDivider()
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.server.name).font(.mtLabelLarge).foregroundStyle(Color.mtOnSurface)
                            Text(([row.server.command] + row.server.args).joined(separator: " "))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                                .lineLimit(1).truncationMode(.middle)
                            Text(ExternalServersModel.statusText(row.status))
                                .font(.mtBodySmall)
                                .foregroundStyle(isFailure(row.status) ? Color.mtError : Color.mtOnSurfaceVariant)
                        }
                        Spacer()
                        Toggle("On", isOn: Binding(
                            get: { row.server.enabled },
                            set: { on in Task { await model.setEnabled(row.id, on) } }))
                            .labelsHidden()
                        Button("Remove") { Task { await model.remove(row.id) } }
                            .buttonStyle(MTOutlinedButtonStyle())
                    }
                }
            }
        }
    }

    private func isFailure(_ s: ExternalServerStatus) -> Bool { if case .failed = s { true } else { false } }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            MTTextField("Name, e.g. GitHub", text: $name)
            MTTextField("Command, e.g. npx", text: $command)
            MTTextField("Arguments, e.g. -y @modelcontextprotocol/server-filesystem /Users/me/Documents", text: $arguments)
            Label("Adding a server lets it run as a program on this Mac. Only add servers you trust.",
                  systemImage: "exclamationmark.triangle")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            if let err = model.lastError {
                Text(err).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
            HStack {
                Spacer()
                Button("Add and start") {
                    Task {
                        await model.add(name: name, command: command, arguments: arguments)
                        if model.lastError == nil { name = ""; command = ""; arguments = ""; adding = false }
                    }
                }
                .buttonStyle(MTFilledButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
#endif
