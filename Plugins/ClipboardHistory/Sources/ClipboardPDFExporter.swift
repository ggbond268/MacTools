import Foundation
import WebKit

@MainActor
final class ClipboardPDFExporter: NSObject, WKNavigationDelegate {
    typealias NavigationStarter = @MainActor (WKWebView, String) -> Void
    typealias PDFCreator = @MainActor (
        WKWebView,
        WKPDFConfiguration,
        @escaping @Sendable (Result<Data, any Error>) -> Void
    ) -> Void

    private var navigationContinuation: CheckedContinuation<Void, any Error>?
    private var pdfContinuation: CheckedContinuation<Data, any Error>?
    private let navigationStarter: NavigationStarter
    private let pdfCreator: PDFCreator

    init(
        navigationStarter: @escaping NavigationStarter = { webView, html in
            webView.loadHTMLString(html, baseURL: nil)
        },
        pdfCreator: @escaping PDFCreator = { webView, configuration, completion in
            webView.createPDF(configuration: configuration, completionHandler: completion)
        }
    ) {
        self.navigationStarter = navigationStarter
        self.pdfCreator = pdfCreator
    }

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
            finishNavigation(.failure(CancellationError()))
            finishPDF(.failure(CancellationError()))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                navigationStarter(webView, html)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelNavigation(in: webView)
            }
        }
        try Task.checkCancellation()

        let pdfConfiguration = WKPDFConfiguration()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pdfContinuation = continuation
                pdfCreator(webView, pdfConfiguration) { [weak self] result in
                    let boxedResult = ClipboardPDFResultBox(result)
                    Task { @MainActor in
                        self?.finishPDF(boxedResult.value)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelPDF(in: webView)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finishNavigation(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let error = WKError(.webContentProcessTerminated)
        finishNavigation(.failure(error))
        finishPDF(.failure(error))
    }

    private func cancelNavigation(in webView: WKWebView) {
        webView.stopLoading()
        finishNavigation(.failure(CancellationError()))
    }

    private func cancelPDF(in webView: WKWebView) {
        webView.stopLoading()
        finishPDF(.failure(CancellationError()))
    }

    private func finishNavigation(_ result: Result<Void, any Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume(with: result)
    }

    private func finishPDF(_ result: Result<Data, any Error>) {
        guard let continuation = pdfContinuation else { return }
        pdfContinuation = nil
        continuation.resume(with: result)
    }

    var hasPendingNavigationForTesting: Bool { navigationContinuation != nil }
    var hasPendingPDFForTesting: Bool { pdfContinuation != nil }
}

private struct ClipboardPDFResultBox: @unchecked Sendable {
    let value: Result<Data, any Error>

    init(_ value: Result<Data, any Error>) {
        self.value = value
    }
}
