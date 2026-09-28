#if canImport(AppKit)
import SwiftUI

struct LocalModelPickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var modelDirectory: URL?
    @State private var isShowingPicker = false
    @State private var isRegistering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Point to a directory containing a model bundle (.safetensors + config.json).")
                .foregroundStyle(.secondary)

            HStack {
                Text(modelDirectory?.path ?? "No directory selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(modelDirectory == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Browse…") { isShowingPicker = true }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(isRegistering ? "Scanning…" : "Continue") {
                guard let url = modelDirectory else { return }
                isRegistering = true
                Task {
                    await services.registerLocalModel(at: url, coordinator: coordinator)
                    isRegistering = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(modelDirectory == nil || isRegistering)
        }
        .fileImporter(isPresented: $isShowingPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { modelDirectory = url }
        }
    }
}
#endif
