#if canImport(AppKit)
import VibeCockpitCore
import SwiftUI

struct LocalModelPickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var modelDirectory: URL?
    @State private var isShowingPicker = false
    @State private var isRegistering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Model Directory")
                    .font(.mtLabelLarge)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                HStack(spacing: 10) {
                    Label(
                        modelDirectory?.lastPathComponent ?? "No directory selected",
                        systemImage: "folder.fill"
                    )
                    .font(.mtBodyMedium)
                    .foregroundStyle(modelDirectory == nil ? Color.mtOnSurfaceVariant : Color.mtOnSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Browse…") { isShowingPicker = true }
                        .buttonStyle(MTOutlinedButtonStyle())
                }
                .padding(14)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.mtOutline, lineWidth: 1)
                )

                Text("Directory must contain config.json and model.safetensors (MLX format).")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }

            Button(isRegistering ? "Scanning…" : "Continue") {
                guard let url = modelDirectory else { return }
                isRegistering = true
                Task {
                    await services.registerLocalModel(at: url, coordinator: coordinator)
                    await services.refreshModels(coordinator: coordinator)
                    isRegistering = false
                }
            }
            .buttonStyle(MTFilledButtonStyle())
            .disabled(modelDirectory == nil || isRegistering)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .fileImporter(isPresented: $isShowingPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { modelDirectory = url }
        }
    }
}
#endif
