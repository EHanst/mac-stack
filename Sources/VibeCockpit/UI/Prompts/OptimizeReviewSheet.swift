#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// Shows a rewrite of the user's prompt and lets them accept, edit or drop it. Nothing is sent
/// to the chat from here.
struct OptimizeReviewSheet: View {
    let studio: PromptStudioModel
    let draft: String
    let onAccept: (String) -> Void
    let onExpand: () -> Void
    let onAskQuestions: ([String]) -> Void
    let onClose: () -> Void

    @AppStorage("kokoroPersonaEnabled") private var persona = true
    @State private var edited = ""
    @State private var tab = Tab.changes
    private enum Tab: String, CaseIterable { case changes = "Changes", edit = "Edit" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            MTDivider()
            content
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 320)
        .onChange(of: studio.phase) { _, phase in
            if case .review(let o) = phase { edited = o.improved }
        }
        .onAppear { if case .review(let o) = studio.phase { edited = o.improved } }
    }

    private var header: some View {
        HStack {
            Label("Improve my prompt", systemImage: "wand.and.stars")
                .font(.mtTitleMedium)
            Spacer()
            if let model = studio.modelID.map(Self.modelLabel) {
                Text("for \(model)").font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch studio.phase {
        case .idle:
            Text("Nothing to show.").foregroundStyle(Color.mtOnSurfaceVariant)
            closeRow
        case .running(let partial):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text(persona ? "Kokoro is thinking it over…" : "Rewriting…").font(.mtBodySmall)
                }
                ScrollView { Text(partial.isEmpty ? " " : partial).font(.mtBodyMedium).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 180)
                Text("A model on this Mac can take a little while. Your original is untouched.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                HStack { Spacer(); Button("Cancel") { studio.cancelOptimize(); onClose() }.buttonStyle(MTTextButtonStyle()) }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.mtBodyMedium).foregroundStyle(Color.mtError)
                .fixedSize(horizontal: false, vertical: true)
            closeRow
        case .review(let result):
            review(result)
        }
    }

    private func review(_ result: Optimization) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let rejection = result.rejection {
                Label(rejection.reason, systemImage: "hand.raised.fill")
                    .font(.mtBodyMedium).foregroundStyle(Color.mtOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if !rejection.missing.isEmpty {
                    Text("Dropped: " + rejection.missing.prefix(6).joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
            if !result.questions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A little more detail would help:").font(.mtLabelLarge)
                    ForEach(result.questions, id: \.self) { Text("• \($0)").font(.mtBodyMedium) }
                }
                HStack {
                    Spacer()
                    Button("Add these to my prompt") { onAskQuestions(result.questions) }.buttonStyle(MTTonalButtonStyle())
                }
            }
            if result.rejection == nil && result.didChange {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Group {
                    if tab == .changes { diff(result) } else { editor }
                }
                .frame(maxHeight: 220)
                notes("Conflicts resolved", result.conflicts, icon: "arrow.triangle.merge")
                notes("Assumed — please confirm", result.assumptions, icon: "questionmark.circle")
                notes(persona ? "Kokoro's notes" : "What changed", result.otherChanges, icon: nil)
                HStack {
                    Button("Keep mine") { studio.dismissReview(); onClose() }.buttonStyle(MTTextButtonStyle())
                    Button("Expand") { onExpand() }.buttonStyle(MTOutlinedButtonStyle())
                        .help("Try again and turn this into a detailed specification")
                    Spacer()
                    Button("Use this") { accept(result) }
                        .buttonStyle(MTFilledButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                if result.rejection == nil && result.questions.isEmpty {
                    Label("That already reads clearly. Nothing to change.", systemImage: "checkmark.circle")
                        .font(.mtBodyMedium).foregroundStyle(Color.mtHealthy)
                }
                HStack {
                    if result.rejection != nil {
                        Button("Try Expand") { onExpand() }.buttonStyle(MTOutlinedButtonStyle())
                    }
                    Spacer()
                    Button("Keep mine") { studio.dismissReview(); onClose() }.buttonStyle(MTFilledButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ title: String, _ items: [String], icon: String?) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let icon { Label(title, systemImage: icon).font(.mtLabelLarge) } else { Text(title).font(.mtLabelLarge) }
                ForEach(items, id: \.self) {
                    Text("• \($0)").font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
            }
        }
    }

    private func diff(_ result: Optimization) -> some View {
        ScrollView {
            Text(Self.attributed(WordDiff.segments(from: result.original, to: edited)))
                .font(.mtBodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.mtSurfaceContainerHighest)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var editor: some View {
        TextEditor(text: $edited)
            .font(.mtBodyMedium)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.mtSurfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var closeRow: some View {
        HStack { Spacer(); Button("Close") { studio.dismissReview(); onClose() }.buttonStyle(MTFilledButtonStyle()) }
    }

    private func accept(_ result: Optimization) {
        let text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        studio.accepted(text: text, replacing: result.original)
        onAccept(text)
    }

    static func attributed(_ segments: [WordDiff.Segment]) -> AttributedString {
        var out = AttributedString()
        for s in segments {
            var part = AttributedString(s.text)
            switch s.kind {
            case .same: break
            case .added:
                part.backgroundColor = Color.mtHealthy.opacity(0.22)
            case .removed:
                part.backgroundColor = Color.mtError.opacity(0.18)
                part.strikethroughStyle = .single
                part.foregroundColor = Color.mtOnSurfaceVariant
            }
            out += part
        }
        return out
    }

    static func modelLabel(_ id: String) -> String {
        id.hasPrefix("local:") ? String(id.dropFirst(6)) + " (on this Mac)" : id + " (cloud)"
    }
}
#endif
