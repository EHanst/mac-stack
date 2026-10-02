#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

// MARK: - Model Manager

struct ModelManagerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @State private var selectedFilter: ModelFilter = .all
    @State private var showAddSheet = false
    @State private var isRefreshing = false

    enum ModelFilter: String, CaseIterable {
        case all = "All"
        case local = "Local"
        case remote = "Remote"
    }

    private var filtered: [ModelInfo] {
        switch selectedFilter {
        case .all:    return coordinator.state.modelInfos
        case .local:  return coordinator.state.modelInfos.filter { $0.kind == .local }
        case .remote: return coordinator.state.modelInfos.filter { $0.kind == .remote }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            MTDivider()
            filterRow
            MTDivider()
            if coordinator.state.modelInfos.isEmpty {
                emptyState
            } else {
                modelList
            }
        }
        .background(Color.mtSurfaceContainerLowest)
        .task { await refreshIfNeeded() }
        .sheet(isPresented: $showAddSheet) {
            AddModelSheet()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models")
                    .font(.mtTitleLarge)
                    .foregroundStyle(Color.mtOnSurface)
                Text("\(coordinator.state.modelInfos.count) provider(s) registered")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
            Button {
                isRefreshing = true
                Task {
                    await services.refreshModels(coordinator: coordinator)
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MTIconButtonStyle(variant: .standard))
            .help("Refresh provider health")

            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(MTIconButtonStyle(variant: .tonal))
            .help("Add model or remote provider")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.mtSurface)
    }

    // MARK: Filter chips

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ModelFilter.allCases, id: \.self) { filter in
                    MTFilterChip(
                        filter.rawValue,
                        icon: filterIcon(filter),
                        selected: selectedFilter == filter
                    ) {
                        selectedFilter = filter
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color.mtSurface)
    }

    private func filterIcon(_ f: ModelFilter) -> String {
        switch f {
        case .all:    return "square.grid.2x2"
        case .local:  return "internaldrive"
        case .remote: return "cloud"
        }
    }

    // MARK: Model list

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filtered) { model in
                    ModelCard(model: model) {
                        Task { await services.unregisterModel(id: model.id, coordinator: coordinator) }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.mtPrimary.opacity(0.5))
            Text("No models configured")
                .font(.mtHeadlineSmall)
                .foregroundStyle(Color.mtOnSurface)
            Text("Add a local MLX model bundle or configure a remote API provider.")
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Add Model") { showAddSheet = true }
                .buttonStyle(MTFilledButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func refreshIfNeeded() async {
        if coordinator.state.modelInfos.isEmpty {
            await services.refreshModels(coordinator: coordinator)
        }
    }
}

// MARK: - Model Card

private struct ModelCard: View {
    let model: ModelInfo
    let onRemove: () -> Void
    @State private var showRemoveConfirm = false

    var body: some View {
        MTCard(elevation: 1) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                capabilityChips
                Divider().background(Color.mtOutlineVariant)
                actionRow
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Kind icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.kind == .local ? Color.mtPrimaryContainer : Color.mtTertiaryContainer)
                    .frame(width: 44, height: 44)
                Image(systemName: model.kind == .local ? "internaldrive.fill" : "cloud.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        model.kind == .local
                            ? Color.mtOnPrimaryContainer
                            : Color.mtOnTertiaryContainer
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.mtTitleMedium)
                    .foregroundStyle(Color.mtOnSurface)
                    .lineLimit(1)
                Text(model.id)
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer()
            healthBadge
        }
    }

    private var healthBadge: some View {
        switch model.health {
        case .healthy:
            return AnyView(MTStatusBadge(label: "Ready", color: .mtHealthy))
        case .degraded(let msg):
            return AnyView(MTStatusBadge(label: "Degraded", color: .mtDegraded)
                .help(msg))
        case .unavailable(let msg):
            return AnyView(MTStatusBadge(label: "Unavailable", color: .mtUnavailable)
                .help(msg))
        }
    }

    private var capabilityChips: some View {
        HStack(spacing: 6) {
            if model.capabilities.contains(.textGeneration) {
                capChip("text.bubble", "Text")
            }
            if model.capabilities.contains(.toolUse) {
                capChip("wrench.and.screwdriver", "Tools")
            }
            if model.capabilities.contains(.embedding) {
                capChip("sparkles", "Embed")
            }
            if model.capabilities.contains(.streaming) {
                capChip("waveform", "Stream")
            }
            if model.capabilities.contains(.speculativeDraft) {
                capChip("bolt.horizontal", "Speculative")
            }
            Spacer()
        }
    }

    private func capChip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.mtLabelSmall)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.mtSurfaceContainerHighest)
        .foregroundStyle(Color.mtOnSurfaceVariant)
        .clipShape(Capsule())
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button("Remove") { showRemoveConfirm = true }
                .buttonStyle(MTOutlinedButtonStyle(tint: .mtError))
                .controlSize(.small)
        }
        .confirmationDialog("Remove \(model.displayName)?",
                            isPresented: $showRemoveConfirm,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { onRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unregisters the provider from \(AppBrand.name). No files are deleted.")
        }
    }
}

// MARK: - Add Model Sheet

struct AddModelSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .local
    @State private var localURL: URL?
    @State private var isShowingPicker = false
    @State private var isBusy = false

    // Remote fields
    @State private var remotePreset = ""
    @State private var remoteID = ""
    @State private var remoteBaseURL = ""
    @State private var remoteModelID = ""
    @State private var remoteToken = ""
    @State private var saveError: String?

    enum Tab: String, CaseIterable { case local = "Local Model"; case remote = "Remote API" }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            MTDivider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Group {
                switch tab {
                case .local:  localForm
                case .remote: remoteForm
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 420)
        .background(Color.mtSurface)
        .fileImporter(isPresented: $isShowingPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { localURL = url }
        }
    }

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Model")
                    .font(.mtHeadlineSmall)
                    .foregroundStyle(Color.mtOnSurface)
                Text("Register a local MLX bundle or a remote API endpoint.")
                    .font(.mtBodyMedium)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(MTIconButtonStyle(variant: .standard))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: Local form

    private var localForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Model Directory")
                    .font(.mtLabelLarge)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
                HStack {
                    Text(localURL?.path ?? "No directory selected")
                        .font(.mtBodyMedium)
                        .foregroundStyle(localURL == nil ? Color.mtOnSurfaceVariant : Color.mtOnSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Browse…") { isShowingPicker = true }
                        .buttonStyle(MTOutlinedButtonStyle())
                }
                .padding(14)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.mtOutline, lineWidth: 1)
                )
                Text("Directory must contain config.json and model.safetensors")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(MTOutlinedButtonStyle())
                Button(isBusy ? "Scanning…" : "Add Model") {
                    guard let url = localURL else { return }
                    isBusy = true
                    Task {
                        await services.registerLocalModel(at: url, coordinator: coordinator)
                        await services.refreshModels(coordinator: coordinator)
                        isBusy = false
                        dismiss()
                    }
                }
                .buttonStyle(MTFilledButtonStyle())
                .disabled(localURL == nil || isBusy)
            }
        }
    }

    // MARK: Remote form

    private var keyOptional: Bool { CloudPreset.preset(id: remotePreset).map { !$0.keyRequired } ?? false }

    private var remoteForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldGroup("Provider", hint: "Pick one to fill in the address for you") {
                Picker("Provider", selection: $remotePreset) {
                    ForEach(CloudPreset.all) { Text($0.name).tag($0.id) }
                    Text("Other").tag("")
                }
                .labelsHidden()
                .onChange(of: remotePreset) { _, id in
                    guard let p = CloudPreset.preset(id: id) else { return }
                    remoteID = p.id
                    remoteBaseURL = p.baseURL.absoluteString
                    remoteModelID = p.suggestedModel ?? ""
                }
            }
            fieldGroup("Provider ID", hint: "e.g. openai, anthropic, custom") {
                MTTextField("provider-id", text: $remoteID)
            }
            fieldGroup("Base URL", hint: "e.g. https://api.openai.com/v1") {
                MTTextField("https://…", text: $remoteBaseURL)
            }
            fieldGroup("Model Identifier", hint: CloudPreset.preset(id: remotePreset)?.modelHint ?? "The provider's model id") {
                MTTextField("model-name", text: $remoteModelID)
            }
            fieldGroup("API Key", hint: CloudPreset.preset(id: remotePreset)?.keyHint ?? "Stored in macOS Keychain") {
                SecureField(keyOptional ? "optional" : "paste key", text: $remoteToken)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mtOutline, lineWidth: 1))
            }
            Spacer()
            if let saveError {
                Text(saveError).font(.mtBodySmall).foregroundStyle(Color.mtError)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(MTOutlinedButtonStyle())
                Button(isBusy ? "Saving…" : "Add Provider") {
                    guard let base = URL(string: remoteBaseURL),
                          !remoteID.isEmpty, keyOptional || !remoteToken.isEmpty,
                          !remoteModelID.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    isBusy = true
                    Task {
                        do {
                            try await services.saveCredentialAndComplete(
                                token: remoteToken.isEmpty ? CloudPreset.placeholderKey : remoteToken,
                                providerID: remoteID,
                                baseURL: base,
                                modelIdentifier: remoteModelID.trimmingCharacters(in: .whitespaces),
                                coordinator: coordinator
                            )
                            await services.refreshModels(coordinator: coordinator)
                            dismiss()
                        } catch {
                            saveError = "Failed to save credentials: \(error.localizedDescription)"
                        }
                        isBusy = false
                    }
                }
                .buttonStyle(MTFilledButtonStyle())
                .disabled(remoteID.isEmpty || remoteBaseURL.isEmpty || (remoteToken.isEmpty && !keyOptional)
                          || remoteModelID.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            }
        }
    }

    private func fieldGroup<C: View>(_ label: String, hint: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.mtLabelLarge).foregroundStyle(Color.mtOnSurfaceVariant)
            content()
            Text(hint).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.7))
        }
    }
}

// MARK: - Minimal text field with Material styling

struct MTTextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(10)
            .background(Color.mtSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mtOutline, lineWidth: 1))
    }
}
#endif
