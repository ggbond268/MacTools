import Foundation
import WebKit

@MainActor
final class ClipboardPDFExporter: NSObject, WKNavigationDelegate {
    private var navigationContinuation: CheckedContinuation<Void, any Error>?

    func render(html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 612, height: 792),
            configuration: configuration
        )
        webView.navigationDelegate = self
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            navigationContinuation = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelNavigation(in: webView)
            }
        }
        try Task.checkCancellation()

        let pdfConfiguration = WKPDFConfiguration()
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: pdfConfiguration) { result in
                continuation.resume(with: result)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private func cancelNavigation(in webView: WKWebView) {
        webView.stopLoading()
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil
    }
}
