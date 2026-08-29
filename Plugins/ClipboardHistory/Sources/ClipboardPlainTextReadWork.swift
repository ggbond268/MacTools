import AppKit
import Foundation

/// Describes a bounded plain-text request for the killable pasteboard reader helper.
enum ClipboardPlainTextReadWork {
    static func request(
        pasteboardName: NSPasteboard.Name,
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) -> ClipboardPasteboardReaderRequest {
        ClipboardPasteboardReaderRequest(
            kind: .plainText,
            pasteboardName: pasteboardName.rawValue,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
    }
}
