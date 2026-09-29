#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import SwiftUI

/// "Cursor wants to change a file" — shown over the window until the user answers.
struct ApprovalSheet: View {
    let request: ApprovalRequest
    let waitingAfterThis: Int
    let answer: (ApprovalDecision) -> Void

    private var headline: String {
        switch request.scope {
        case .toolsExec: "\(request.client.name) wants to run a command"
        case .toolsWrite: "\(request.client.name) wants to change your files"
        default: "\(request.client.name) wants to do something"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(headline, systemImage: request.scope == .toolsExec ? "terminal" : "square.and.pencil")
                .font(.mtTitleMedium)
                .foregroundStyle(Color.mtOnSurface)
            Text(request.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.mtSurfaceContainerLowest, in: RoundedRectangle(cornerRadius: 8))
            if request.untrustedSources.isEmpty {
                Text("You can take back \"Always allow\" any time in Settings → Share with other apps.")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtOnSurfaceVariant)
            } else {
                Label("This conversation includes text from outside (\(request.untrustedSources.joined(separator: ", "))). It may be trying to steer this action, so check it before allowing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.mtBodySmall)
                    .foregroundStyle(Color.mtError)
            }
            if waitingAfterThis > 0 {
                Text("\(waitingAfterThis) more waiting after this one.")
                    .font(.mtBodySmall).foregroundStyle(Color.mtOnSurfaceVariant)
            }
            HStack {
                Button("Don't allow") { answer(.deny) }.keyboardShortcut(.cancelAction)
                Spacer()
                if request.untrustedSources.isEmpty {
                    Button("Always allow this") { answer(.allowAlways) }
                }
                Button("Allow once") { answer(.allowOnce) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
#endif
