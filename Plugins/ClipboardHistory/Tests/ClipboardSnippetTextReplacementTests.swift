import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSnippetTextReplacementTests: XCTestCase {
    func testDelayedKeywordSelectionCanCatchUpWithoutSelectingAgain() async {
        let access = FakeSnippetReplacementAccess()
        access.selectionReady = false
        access.nativeWorks = true
        var waits = 0
        let result = await ClipboardSnippetTextReplacement.perform(using: access) {
            waits += 1
            if waits == 2 { access.selectionReady = true }
        }
        XCTAssertTrue(result)
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(access.nativeAttempts, 1)
    }

    func testChangedContextDuringSelectionWaitNeverReplacesText() async {
        let access = FakeSnippetReplacementAccess()
        access.selectionReady = false
        let result = await ClipboardSnippetTextReplacement.perform(using: access) {
            access.ownsSelection = false
        }
        XCTAssertFalse(result)
        XCTAssertEqual(access.nativeAttempts, 0)
        XCTAssertEqual(access.pastes, 0)
    }

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

    func testDelayedNativeReplacementDoesNotDoubleInsert() async {
        let access = FakeSnippetReplacementAccess()
        var waits = 0
        let result = await ClipboardSnippetTextReplacement.perform(using: access) {
            waits += 1
            if waits == 3 { access.expanded = true }
        }
        XCTAssertTrue(result)
        XCTAssertEqual(access.pastes, 0)
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

    func testPostedButUnconfirmedPasteIsNotReportedAsExpanded() async {
        let access = FakeSnippetReplacementAccess()
        access.canPost = true
        let result = await ClipboardSnippetTextReplacement.perform(using: access, pause: {})
        XCTAssertFalse(result)
        XCTAssertEqual(access.pastes, 1)
        XCTAssertEqual(access.clipboardRestores, 1)
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

    func testCancellationAfterPostingWaitsForDeliveryBeforeRestoringClipboard() async {
        let access = FakeSnippetReplacementAccess()
        access.canPost = true
        var task: Task<Bool, Never>?
        var deliveryWaits = 0
        task = Task { @MainActor in
            await ClipboardSnippetTextReplacement.perform(using: access) {
                if access.pastes > 0 {
                    task?.cancel()
                    deliveryWaits += 1
                    XCTAssertEqual(access.clipboardRestores, 0)
                    if deliveryWaits == 3 { access.expanded = true }
                }
            }
        }
        let result = await task!.value
        XCTAssertFalse(result)
        XCTAssertEqual(deliveryWaits, 3)
        XCTAssertEqual(access.clipboardRestores, 1)
        XCTAssertEqual(access.cursorPlacements, 0)
    }

    func testPasteboardLeasePreservesAllRepresentationsAndItems() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([1, 2, 3]), forType: .init("com.example.custom"))
        let second = NSPasteboardItem()
        second.setData(Data([4, 5, 6]), forType: .png)
        board.writeObjects([first, second])
        var writes = 0
        let lease = try XCTUnwrap(ClipboardSnippetPasteboardLease(pasteboard: board, onWrite: { writes += 1 }))
        XCTAssertTrue(lease.write("replacement"))
        XCTAssertEqual(board.string(forType: .string), "replacement")
        XCTAssertTrue(board.types!.contains(ClipboardSnippetPasteboardLease.generatedType))
        lease.restore()
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .init("com.example.custom")), Data([1, 2, 3]))
        XCTAssertEqual(board.pasteboardItems?[1].data(forType: .png), Data([4, 5, 6]))
        XCTAssertFalse(board.types!.contains(ClipboardSnippetPasteboardLease.generatedType))
        XCTAssertEqual(writes, 2)
    }

    func testLeaseNeverOverwritesNewUserCopy() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let lease = try XCTUnwrap(ClipboardSnippetPasteboardLease(pasteboard: board, onWrite: {}))
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
            XCTAssertNil(ClipboardSnippetPasteboardLease(pasteboard: board, onWrite: {}))
            XCTAssertEqual(board.types, [.init(type)])
        }
    }

    func testLeasePreservesEmptyClipboardAndRejectsCopyDuringPreparation() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let lease = try XCTUnwrap(ClipboardSnippetPasteboardLease(pasteboard: board, onWrite: {}))
        XCTAssertTrue(lease.write("snippet"))
        lease.restore()
        XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
        let stale = try XCTUnwrap(ClipboardSnippetPasteboardLease(pasteboard: board, onWrite: {}))
        board.clearContents()
        board.setString("new", forType: .string)
        XCTAssertFalse(stale.write("snippet"))
        XCTAssertEqual(board.string(forType: .string), "new")
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
    func pasteReplacement() -> Bool { pastes += 1; expanded = pasteWorks; return canPost || pasteWorks }
    func restoreClipboard() { clipboardRestores += 1 }
    func restoreSelection() { selectionRestores += 1 }
    func positionCursor() { cursorPlacements += 1 }
}
