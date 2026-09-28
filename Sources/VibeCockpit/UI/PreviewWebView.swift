#if canImport(AppKit)
import VibeCockpitCore
import SwiftUI
import WebKit

struct PreviewWebView: NSViewRepresentable {
    let html: String
    var javaScriptEnabled: Bool = false

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = javaScriptEnabled
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.configuration.preferences.javaScriptEnabled = javaScriptEnabled
        // baseURL: nil → no origin, no CORS surface
        nsView.loadHTMLString(html, baseURL: nil)
    }
}
#endif
