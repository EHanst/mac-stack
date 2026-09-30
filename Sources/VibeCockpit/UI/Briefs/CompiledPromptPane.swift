#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI
import AppKit

/// Right column: exactly what the frontier model will receive, plus target and Copy.
struct CompiledPromptPane: View {
    @Environment(AppServices.self) private var services
    @State private var copied = false

    private var model: BriefWorkbenchModel { services.briefs }

    var body: some View {
        if let brief = model.selected, let compiled = model.compiled {
            VStack(alignment: .leading, spacing: 12) {
                targetPicker(brief)
                meter(brief, compiled)
                ForEach(Array(compiled.warnings.enumerated()), id: \.offset) { _, w in
                    Label(w.message, systemImage: "exclamationmark.triangle")
                        .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                ScrollView {
                    Text(compiled.text.isEmpty ? "Your prompt appears here as you write the goal." : compiled.text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(10)
                }
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                copyBar
            }
            .padding(16)
            .background(Color.mtSurfaceContainerLowest)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 40))
                    .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.4))
                Text("The finished prompt shows here").font(.mtTitleMedium)
                    .foregroundStyle(Color.mtOnSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mtSurfaceContainerLowest)
        }
    }

    private func targetPicker(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(get: { brief.target.modelFamily },
                                               set: { model.setTarget(modelFamily: $0, surface: brief.target.surface) })) {
                Text("Claude").tag("claude"); Text("GPT").tag("gpt"); Text("Other").tag("generic")
            }
            Picker("Where", selection: Binding(get: { brief.target.surface },
                                               set: { model.setTarget(modelFamily: brief.target.modelFamily, surface: $0) })) {
                ForEach(Surface.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        .pickerStyle(.menu)
    }

    private func meter(_ brief: Brief, _ compiled: CompiledPrompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(Double(compiled.tokens), Double(brief.target.tokenBudget)),
                         total: Double(max(brief.target.tokenBudget, 1)))
            Text("About \(compiled.tokens.formatted()) of \(brief.target.tokenBudget.formatted()) tokens")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
        }
    }

    private var copyBar: some View {
        let empty = model.copyText(for: nil).isEmpty
        return HStack {
            Button { copy(nil) } label: { Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                .buttonStyle(MTFilledButtonStyle())
                .disabled(empty)
            Menu("Copy for…") {
                Button("Claude Code") { copy(.claudeCode) }
                Button("ChatGPT") { copy(.chatGPTWeb) }
            }
            .disabled(empty)
        }
    }

    private func copy(_ surface: Surface?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyText(for: surface), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
#endif
