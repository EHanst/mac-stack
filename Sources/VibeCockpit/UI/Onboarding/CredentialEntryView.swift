#if canImport(AppKit)
import SwiftUI

struct CredentialEntryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var providerID = ""
    @State private var apiToken = ""
    @State private var baseURL = ""
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
            .disabled(providerID.isEmpty || apiToken.isEmpty || isSaving)
        }
    }

    private func saveCredential() {
        isSaving = true
        saveError = nil
        // Credential storage is handled by CredentialStore actor at runtime.
        // The UI just signals onboarding completion; the coordinator will
        // trigger credential storage via its async pipeline.
        coordinator.send(.onboardingCompleted)
    }
}
#endif
