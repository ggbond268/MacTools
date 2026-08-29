import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardPlainTextReadWorkerTests: XCTestCase {
    func testRequestUsesBoundedPlainTextHelperOperation() {
        let pasteboardName = NSPasteboard.Name("ClipboardPlainTextReadWorkerTests")
        let request = ClipboardPlainTextReadWork.request(
            pasteboardName: pasteboardName,
            maximumByteCount: 4_096,
            expectedChangeCount: 42
        )

        XCTAssertEqual(request.kind, .plainText)
        XCTAssertEqual(request.pasteboardName, pasteboardName.rawValue)
        XCTAssertEqual(request.maximumByteCount, 4_096)
        XCTAssertEqual(request.expectedChangeCount, 42)
    }
}
