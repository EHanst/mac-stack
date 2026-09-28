#if canImport(AppKit)
import SwiftUI

struct CredentialEntryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var providerID = ""
    @State private var apiToken = ""
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter credentials for an OpenAI-compatible remote provider. Tokens are stored in the macOS Keychain — never on disk.")
                .foregroundStyle(.secondary)

            LabeledContent("Provider ID") {
                TextField("e.g. my-openai", text: $providerID)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Base URL") {
                TextField("https://api.openai.com/v1", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("API Token") {
                SecureField("sk-…", text: $apiToken)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = saveError {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            Button(isSaving ? "Saving…" : "Save to Keychain") {
                saveCredential()
            }
            .buttonStyle(.borderedProminent)
            .disabled(providerID.isEmpty || apiToken.isEmpty || baseURL.isEmpty || isSaving)
        }
    }

    private func saveCredential() {
        guard let url = URL(string: baseURL), !url.host.isNilOrEmpty else {
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
                    coordinator: coordinator
                )
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self == nil || self! .isEmpty }
}
#endif
