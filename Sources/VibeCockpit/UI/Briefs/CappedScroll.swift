#if canImport(AppKit)
import SwiftUI

/// Only as tall as its content, up to `maxHeight`; beyond that it scrolls. Keeps short rows from
/// leaving a gap and long ones from pushing the editor or copy bar out of view.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat = 220
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, h in contentHeight = h }
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
    }
}
#endif
