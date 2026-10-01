#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

struct CredentialEntryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var providerID = ""
    @State private var apiToken = ""
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var modelID = ""
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tokens are stored in the macOS Keychain — never written to disk.")
                .font(.mtBodySmall)
                .foregroundStyle(Color.mtOnSurfaceVariant)

            fieldGroup("Provider ID", hint: "e.g. my-openai, anthropic") {
                MTTextField("provider-id", text: $providerID)
            }

            fieldGroup("Base URL", hint: "OpenAI-compatible v1 endpoint") {
                MTTextField("https://api.openai.com/v1", text: $baseURL)
            }

            fieldGroup("Model", hint: "The provider's model id, e.g. claude-sonnet-5-5 with https://api.anthropic.com") {
                MTTextField("model-name", text: $modelID)
            }

            fieldGroup("API Token", hint: "Stored securely in Keychain") {
                SecureField("sk-…", text: $apiToken)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mtOutline, lineWidth: 1))
            }

            if let err = saveError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtError)
                    .padding(10)
                    .background(Color.mtErrorContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button(isSaving ? "Saving…" : "Save to Keychain") {
                saveCredential()
            }
            .buttonStyle(MTFilledButtonStyle())
            .disabled(providerID.isEmpty || apiToken.isEmpty || baseURL.isEmpty || modelID.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func fieldGroup<C: View>(_ label: String, hint: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
            content()
            Text(hint).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.7))
        }
    }

    private func saveCredential() {
        guard let url = URL(string: baseURL), url.host != nil else {
            saveError = "Enter a valid base URL."
            return
        }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await services.saveCredentialAndComplete(
                    token: apiToken,
                    providerID: providerID,
                    baseURL: url,
                    modelIdentifier: modelID.trimmingCharacters(in: .whitespaces),
                    coordinator: coordinator
                )
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}
#endif
