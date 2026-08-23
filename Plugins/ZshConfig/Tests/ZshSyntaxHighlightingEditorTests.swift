import AppKit
import SwiftUI
import XCTest
@testable import ZshConfigPlugin

@MainActor
final class ZshSyntaxHighlightingEditorTests: XCTestCase {
    private var bindingValue = ""

    func testTextChangeDefersHighlightingUntilTypingPauses() {
        bindingValue = "alias ll='ls -la'"
        var highlightCount = 0
        let editor = makeEditor()
        let coordinator = ZshSyntaxHighlightingEditor.Coordinator(
            editor,
            highlightingDelay: 0.01,
            highlighter: { _ in highlightCount += 1 }
        )
        let textView = NSTextView()
        textView.string = bindingValue

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(bindingValue, "alias ll='ls -la'")
        XCTAssertEqual(highlightCount, 0)

        let expectation = expectation(description: "highlighting completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(highlightCount, 1)
    }

    func testRapidTextChangesCoalesceIntoOneHighlightingPass() {
        bindingValue = "alias first='echo first'"
        var highlightedText: [String] = []
        let editor = makeEditor()
        let coordinator = ZshSyntaxHighlightingEditor.Coordinator(
            editor,
            highlightingDelay: 0.01,
            highlighter: { highlightedText.append($0.string) }
        )
        let textView = NSTextView()

        textView.string = "alias first='echo first'"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        textView.string = "alias second='echo second'"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let expectation = expectation(description: "coalesced highlighting completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(highlightedText, ["alias second='echo second'"])
        XCTAssertEqual(bindingValue, "alias second='echo second'")
    }

    func testCancellingPendingHighlightingPreventsThePass() {
        bindingValue = "export PATH=/usr/local/bin"
        var highlightCount = 0
        let editor = makeEditor()
        let coordinator = ZshSyntaxHighlightingEditor.Coordinator(
            editor,
            highlightingDelay: 0.01,
            highlighter: { _ in highlightCount += 1 }
        )
        let textView = NSTextView()
        textView.string = bindingValue

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.cancelPendingHighlighting()

        let expectation = expectation(description: "cancelled highlighting would have completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(highlightCount, 0)
    }

    func testHighlightingPreservesSelection() {
        let textView = NSTextView()
        textView.string = "alias ll='ls -la'\n# comment"
        let selection = NSRange(location: 7, length: 2)
        textView.setSelectedRange(selection)

        ZshSyntaxHighlightingEditor.applyHighlighting(to: textView)

        XCTAssertEqual(textView.selectedRange(), selection)
    }

    func testHighlightingPreservesScrollOrigin() throws {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.string = (0 ..< 200).map { "alias item\($0)='echo \($0)'" }.joined(separator: "\n")
        textView.frame = NSRect(x: 0, y: 0, width: 240, height: 4_000)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        let origin = scrollView.contentView.bounds.origin

        ZshSyntaxHighlightingEditor.applyHighlighting(to: textView)

        XCTAssertEqual(scrollView.contentView.bounds.origin.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, origin.y, accuracy: 0.001)
    }

    private func makeEditor() -> ZshSyntaxHighlightingEditor {
        ZshSyntaxHighlightingEditor(
            text: Binding(
                get: { self.bindingValue },
                set: { self.bindingValue = $0 }
            )
        )
    }
}
