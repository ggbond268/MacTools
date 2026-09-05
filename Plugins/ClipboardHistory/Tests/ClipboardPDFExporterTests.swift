import WebKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardPDFExporterTests: XCTestCase {
    func testContentProcessTerminationFailsPendingNavigationExactlyOnce() async throws {
        let exporter = ClipboardPDFExporter(navigationStarter: { _, _ in })
        let renderTask = Task { try await exporter.render(html: "<p>Clipboard</p>") }
        try await waitUntil { exporter.hasPendingNavigationForTesting }

        let webView = WKWebView()
        exporter.webViewWebContentProcessDidTerminate(webView)
        exporter.webViewWebContentProcessDidTerminate(webView)

        do {
            _ = try await renderTask.value
            XCTFail("A terminated WebKit process must fail the export")
        } catch let error as WKError {
            XCTAssertEqual(error.code, .webContentProcessTerminated)
        }
    }

    func testCancellationDuringPDFGenerationReturnsWithoutWaitingForLateCallback() async throws {
        let completionBox = PDFCompletionBox()
        let exporter = ClipboardPDFExporter(
            navigationStarter: { _, _ in },
            pdfCreator: { _, _, completion in completionBox.store(completion) }
        )
        let renderTask = Task { try await exporter.render(html: "<p>Clipboard</p>") }
        try await waitUntil { exporter.hasPendingNavigationForTesting }
        exporter.webView(WKWebView(), didFinish: nil)
        try await waitUntil { exporter.hasPendingPDFForTesting }

        renderTask.cancel()
        do {
            _ = try await renderTask.value
            XCTFail("Cancellation must finish the pending PDF phase")
        } catch is CancellationError {
            // Expected.
        }
        completionBox.take()?(.success(Data("late".utf8)))
        XCTAssertFalse(exporter.hasPendingPDFForTesting)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for exporter phase")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class PDFCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Data, any Error>) -> Void)?

    func store(_ completion: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        lock.withLock { self.completion = completion }
    }

    func take() -> (@Sendable (Result<Data, any Error>) -> Void)? {
        lock.withLock {
            defer { completion = nil }
            return completion
        }
    }
}
