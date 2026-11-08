import SwiftUI
import WebKit

struct MetaLoginView: UIViewRepresentable {
    let request: MetaLoginRequest
    let completed: (URL) -> Void
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed, failed: failed) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        for scheme in ["fb-viewapp", "oculus"] { configuration.setURLSchemeHandler(context.coordinator, forURLScheme: scheme) }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.load(URLRequest(url: request.url)); return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.finished = true; view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
        let completed: (URL) -> Void; let failed: () -> Void
        var finished = false
        init(completed: @escaping (URL) -> Void, failed: @escaping () -> Void) { self.completed = completed; self.failed = failed }
        private func capture(_ url: URL) {
            guard !finished else { return }; finished = true; completed(url)
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            capture(urlSchemeTask.request.url!)
            urlSchemeTask.didFailWithError(URLError(.cancelled))
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if ["fb-viewapp", "oculus"].contains(url.scheme ?? "") { capture(url); decisionHandler(.cancel); return }
            // Login content stays in-process; never launch another app or plaintext URL.
            guard url.scheme == "https" || url.absoluteString == "about:blank" else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }; finished = true; failed()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }; finished = true; failed()
        }
    }
}
