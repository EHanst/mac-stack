#if canImport(AppKit)
#if SWIFT_PACKAGE
import KokoroCore
#endif
import SwiftUI

/// A sheet for pasting a long text (the frontier model's answer, or a whole session) and acting on it.
struct ReplySheet: View {
    let title: String
    let prompt: String
    let action: String
    let onSubmit: (String) -> Void
    let onClose: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.mtTitleMedium)
            Text(prompt).font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            TextEditor(text: $text)
                .font(.mtBodyMedium)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.mtSurfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            MTSheetFooter(
                cancelTitle: "Cancel",
                primaryTitle: action,
                isPrimaryDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: onClose,
                onPrimary: {
                    onSubmit(text)
                    onClose()
                }
            )
        }
        .padding(Spacing.xxl)
        .frame(width: 560, height: 380)
    }
}
#endif
