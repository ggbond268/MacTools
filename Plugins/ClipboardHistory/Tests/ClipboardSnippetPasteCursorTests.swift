import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSnippetPasteCursorTests: XCTestCase {
    func testReadyInsertionMovesCursorWithoutAnyDelay() async throws {
        let expansion = ClipboardSnippetExpansion(text: "Hello 🌍 end", cursorOffsetFromEnd: 4)
        let context = try XCTUnwrap(ClipboardSnippetPasteCursorContext(selection: CFRange(location: 3, length: 0), expansion: expansion))
        let access = CursorAccess(text: "abc" + expansion.text, selection: CFRange(location: 3 + expansion.text.utf16.count, length: 0))
        var pauses = 0
        await context.apply(access: access, pause: { pauses += 1 })
        XCTAssertEqual(access.movedTo, 3 + expansion.text.utf16.count - 4)
        XCTAssertEqual(pauses, 0)
    }

    func testLaggingInsertionWaitsWithoutTouchingOriginalCaret() async throws {
        let context = try XCTUnwrap(ClipboardSnippetPasteCursorContext(selection: CFRange(location: 0, length: 0),
            expansion: ClipboardSnippetExpansion(text: "hello world", cursorOffsetFromEnd: 5)))
        let access = CursorAccess(text: "", selection: CFRange(location: 0, length: 0))
        await context.apply(access: access, pause: {
            XCTAssertNil(access.movedTo)
            access.value = "hello world"
            access.selection = CFRange(location: 11, length: 0)
        })
        XCTAssertEqual(access.movedTo, 6)
    }

    func testFocusInputSelectionAndContentChangesPreventCaretMovement() async throws {
        let context = try XCTUnwrap(ClipboardSnippetPasteCursorContext(selection: CFRange(location: 0, length: 0),
            expansion: ClipboardSnippetExpansion(text: "hello world", cursorOffsetFromEnd: 5)))
        for variant in 0..<4 {
            let access = CursorAccess(text: "hello world", selection: CFRange(location: 11, length: 0))
            switch variant {
            case 0: access.ownsUnchangedFocus = false
            case 1: access.selection = CFRange(location: 12, length: 0)
            case 2: access.selection = CFRange(location: 11, length: 1)
            default: access.value = "other words"
            }
            await context.apply(access: access, pause: {})
            XCTAssertNil(access.movedTo)
        }
    }

    func testMissingInsertionTimesOutAndCancellationDoesNotMoveCaret() async throws {
        let context = try XCTUnwrap(ClipboardSnippetPasteCursorContext(selection: CFRange(location: 0, length: 0),
            expansion: ClipboardSnippetExpansion(text: "hello", cursorOffsetFromEnd: 2)))
        let access = CursorAccess(text: "", selection: CFRange(location: 0, length: 0))
        var pauses = 0
        await context.apply(access: access, pause: { pauses += 1 })
        XCTAssertEqual(pauses, 10)
        XCTAssertNil(access.movedTo)
        let task = Task { await context.apply(access: access, pause: { throw CancellationError() }) }
        task.cancel()
        await task.value
        XCTAssertNil(access.movedTo)
    }

    func testLargeSnippetValidationReadsOnlySmallBoundaryRanges() async throws {
        let text = String(repeating: "x", count: 1_000_000)
        let context = try XCTUnwrap(ClipboardSnippetPasteCursorContext(selection: CFRange(location: 0, length: 0),
            expansion: ClipboardSnippetExpansion(text: text, cursorOffsetFromEnd: 1)))
        let access = CursorAccess(text: text, selection: CFRange(location: text.utf16.count, length: 0))
        await context.apply(access: access, pause: {})
        XCTAssertEqual(access.movedTo, 999_999)
        XCTAssertEqual(access.readLengths, [32, 32])
    }

    func testInputWhileWaitingAbandonsCursorPlacementEvenIfCaretReturns() async throws {
        let context = try XCTUnwrap(ClipboardSnippetPasteCursorContext(selection: CFRange(location: 0, length: 0),
            expansion: ClipboardSnippetExpansion(text: "hello", cursorOffsetFromEnd: 2)))
        let access = CursorAccess(text: "", selection: CFRange(location: 0, length: 0))
        await context.apply(access: access, pause: {
            access.value = "hello"
            access.selection = CFRange(location: 5, length: 0)
            access.ownsUnchangedFocus = false
        })
        XCTAssertNil(access.movedTo)
    }
}

@MainActor
private final class CursorAccess: ClipboardSnippetPasteCursorAccess {
    var ownsUnchangedFocus = true
    var selection: CFRange?
    var value: String
    var movedTo: Int?
    var readLengths: [Int] = []
    init(text: String, selection: CFRange) { value = text; self.selection = selection }
    func text(in range: CFRange) -> String? {
        readLengths.append(range.length)
        let text = value as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= text.length else { return nil }
        return text.substring(with: NSRange(location: range.location, length: range.length))
    }
    func move(to location: Int) { movedTo = location }
}
