import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSnippetTextReplacementTests: XCTestCase {

    func testNativeReplacementIsVerifiedWithoutTouchingClipboard() async {
        let access = FakeSnippetReplacementAccess()
        access.nativeWorks = true
        let result = await ClipboardSnippetTextReplacement.perform(using: access, pause: {})
        XCTAssertTrue(result)
        XCTAssertEqual(access.pastes, 0)
        XCTAssertEqual(access.cursorPlacements, 1)
    }

    func testSuccessfulButNoOpAXWriteFallsBackExactlyOnce() async {
        let access = FakeSnippetReplacementAccess()
        access.pasteWorks = true
        let result = await ClipboardSnippetTextReplacement.perform(using: access, pause: {})
        XCTAssertTrue(result)
        XCTAssertEqual(access.nativeAttempts, 1)
        XCTAssertEqual(access.pastes, 1)
        XCTAssertEqual(access.clipboardRestores, 1)
        XCTAssertEqual(access.selectionRestores, 0)
    }

    func testChangedFocusOrSelectionNeverPastesOrRestoresSelection() async {
        let access = FakeSnippetReplacementAccess()
        let result = await ClipboardSnippetTextReplacement.perform(using: access) {
            access.ownsSelection = false
        }
        XCTAssertFalse(result)
        XCTAssertEqual(access.pastes, 0)
        XCTAssertEqual(access.selectionRestores, 0)
        XCTAssertEqual(access.cursorPlacements, 0)
    }

    func testUnchangedKeywordIsRestoredAfterPasteFailure() async {
        let access = FakeSnippetReplacementAccess()
        let result = await ClipboardSnippetTextReplacement.perform(using: access, pause: {})
        XCTAssertFalse(result)
        XCTAssertEqual(access.pastes, 1)
        XCTAssertEqual(access.clipboardRestores, 1)
        XCTAssertEqual(access.selectionRestores, 1)
        XCTAssertEqual(access.cursorPlacements, 0)
    }

    func testCancelledBeforeFallbackDoesNotPasteOrMoveCaret() async {
        let access = FakeSnippetReplacementAccess()
        let task = Task { @MainActor in
            await ClipboardSnippetTextReplacement.perform(using: access) {
                throw CancellationError()
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(access.pastes, 0)
        XCTAssertEqual(access.selectionRestores, 0)
    }

    func testLeaseNeverOverwritesNewUserCopy() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let lease = try XCTUnwrap(makeLease(pasteboard: board))
        XCTAssertTrue(lease.write("snippet"))
        board.clearContents()
        board.setString("new user copy", forType: .string)
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testLeaseRejectsPrivateAndPromisedDataBeforeReadingIt() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for type in ["org.nspasteboard.ConcealedType", "com.apple.filepromise"] {
            board.clearContents()
            board.setData(Data(), forType: .init(type))
            XCTAssertNil(makeLease(pasteboard: board))
            XCTAssertEqual(board.types, [.init(type)])
        }
    }

    private func makeLease(
        pasteboard: NSPasteboard,
        onWrite: @escaping () -> Void = {}
    ) -> ClipboardSnippetPasteboardLease? {
        let changeCount = pasteboard.changeCount
        let response = ClipboardPasteboardReaderWire.read(.init(
            kind: .completeSnapshot,
            pasteboardName: pasteboard.name.rawValue,
            maximumByteCount: ClipboardSnippetPasteboardLease.maximumBackupByteCount,
            expectedChangeCount: changeCount
        ))
        return ClipboardSnippetPasteboardLease.makeForTesting(
            pasteboard: pasteboard,
            response: response,
            originalChangeCount: changeCount,
            onWrite: onWrite
        )
    }

    private static var helperURL: URL? {
        var directory = Bundle(for: Self.self).bundleURL
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("ClipboardHistory.bundle", isDirectory: true)
                .appendingPathComponent("Contents/Resources/PasteboardReaderHelper", isDirectory: true)
                .appendingPathComponent("mactools-clipboard-pasteboard-reader-helper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

@MainActor
private final class FakeSnippetReplacementAccess: ClipboardSnippetReplacementAccess {
    var ownsSelection = true
    var selectionReady = true
    var nativeWorks = false
    var pasteWorks = false
    var canPost = false
    var expanded = false
    var nativeAttempts = 0
    var pastes = 0
    var clipboardRestores = 0
    var selectionRestores = 0
    var cursorPlacements = 0
    func originalContextIsValid() -> Bool { ownsSelection && !selectionReady && !expanded }
    func keywordIsSelected() -> Bool { ownsSelection && selectionReady && !expanded }
    func replacementIsPresent() -> Bool { ownsSelection && expanded }
    func replaceUsingAccessibility() { nativeAttempts += 1; expanded = nativeWorks }
    func pasteReplacement() async -> Bool { pastes += 1; expanded = pasteWorks; return canPost || pasteWorks }
    func restoreClipboard() { clipboardRestores += 1 }
    func restoreSelection() { selectionRestores += 1; selectionReady = false }
    func positionCursor() { cursorPlacements += 1 }
}
