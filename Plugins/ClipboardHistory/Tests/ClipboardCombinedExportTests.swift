import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardCombinedExportTests: XCTestCase {
    func testHTMLDocumentEscapesClipboardTextAndPreservesLineBreaks() {
        let html = ClipboardCombinedExportCoordinator.HTMLDocument(
            text: "<script>alert(\"x\")</script>\nSecond & third"
        )

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("Second &amp; third"))
        XCTAssertTrue(html.contains("white-space: pre-wrap"))
    }
}
