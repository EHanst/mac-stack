#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

/// A prompt that came with a project folder. The user reads it before it can be used.
struct ReviewProjectPromptSheet: View {
    let studio: PromptStudioModel
    let entry: WorkspacePromptStore.Entry
    /// Called after approval with the prompt, so the caller can use it right away.
    let onApproved: (SavedPrompt) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(entry.prompt.title, systemImage: "shippingbox").font(.mtTitleMedium)
            Text("From the project “\(entry.workspace)”, file \(entry.fileName). Someone else may have written it, so read it first. Approving only lets you use this text and lets apps you've allowed read it; it can't run anything or change a setting. If the file changes later, you'll be asked again.")
                .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(entry.prompt.body).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 260).padding(10)
            .background(Color.mtSurfaceContainerHighest).clipShape(RoundedRectangle(cornerRadius: 8))
            MTSheetFooter(
                cancelTitle: "Not now",
                primaryTitle: entry.approved ? "Use" : "Approve and use",
                onCancel: onCancel,
                onPrimary: {
                    Task {
                        if !entry.approved { await studio.approve(entry) }
                        onApproved(entry.prompt)
                    }
                }
            )
        }
        .padding(Spacing.xxl)
        .frame(width: 500)
    }
}
#endif
