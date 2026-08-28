import AppKit
import Foundation

/// A stalled lazy pasteboard owner cannot be interrupted, so cancellation must not
/// release its physical read slot. Queued, cancelled callers are skipped on entry.
actor ClipboardPlainTextReadWorker {
    func read(_ operation: @Sendable () -> ClipboardPasteboardReadResult) -> ClipboardPasteboardReadResult {
        guard !Task.isCancelled else { return .changed }
        let result = operation()
        return Task.isCancelled ? .changed : result
    }
}

enum ClipboardPlainTextReadWork {
    private static let worker = ClipboardPlainTextReadWorker()

    static func read(
        pasteboardName: NSPasteboard.Name,
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        await worker.read {
            let board = NSPasteboard(name: pasteboardName)
            guard board.changeCount == expectedChangeCount else { return .changed }
            let text = board.string(forType: .string)
            guard !Task.isCancelled, board.changeCount == expectedChangeCount else { return .changed }
            guard let text else { return .empty }
            guard text.utf8.count <= max(0, maximumByteCount) else { return .oversized }
            return .payload(.plainText(text))
        }
    }
}
