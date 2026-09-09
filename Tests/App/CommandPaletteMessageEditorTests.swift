import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteMessageEditorTests: XCTestCase {
    func testNativeMarkedTextAndUnmarkReportCompositionState() async throws {
        let fixture = MessageEditorFixture()
        defer { fixture.close() }
        let editor = try await fixture.editor()

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(fixture.compositions, [true])
        XCTAssertEqual(fixture.text, "ni")

        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(fixture.compositions, [true, false])
        XCTAssertEqual(fixture.committedTexts, ["ni"])
    }

    func testNativeCommitUpdatesTextBeforeEnablingSubmission() async throws {
        let fixture = MessageEditorFixture()
        defer { fixture.close() }
        let editor = try await fixture.editor()
        editor.insertText("Hello ", replacementRange: NSRange(location: 0, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 6, length: 0))
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(fixture.compositions, [true, false])
        XCTAssertEqual(fixture.text, "Hello 你")
        XCTAssertEqual(fixture.committedTexts, ["Hello 你"])
    }

    func testReturnDoesNotSubmitMarkedTextAndPreservesCommittedMultilineText() async throws {
        let fixture = MessageEditorFixture()
        defer { fixture.close() }
        let editor = try await fixture.editor()
        let delegate = try XCTUnwrap(editor.delegate as? CommandPaletteMessageEditor.Coordinator)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))

        XCTAssertFalse(delegate.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(fixture.submissions.isEmpty)

        let message = "Hi \n第二行 👋  "
        editor.insertText(message, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(delegate.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(fixture.submissions, [message])
    }
}

@MainActor
private final class MessageEditorFixture {
    var text = ""
    var compositions: [Bool] = []
    var committedTexts: [String] = []
    var submissions: [String] = []
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        let view = CommandPaletteMessageEditor(
            text: Binding(get: { [weak self] in self?.text ?? "" }, set: { [weak self] in self?.text = $0 }),
            onSubmit: { [weak self] in
                guard let self else { return }
                submissions.append(text)
            }, onBack: {},
            onCompositionChange: { [weak self] marked in
                guard let self else { return }
                compositions.append(marked)
                if !marked { committedTexts.append(text) }
            }
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
    }

    func editor() async throws -> NSTextView {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0 ..< 60 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = window.contentView,
               let editor = descendants(content).compactMap({ $0 as? NSTextView }).first {
                window.makeFirstResponder(editor)
                return editor
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(nil as NSTextView?, "The native message editor did not become available")
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
