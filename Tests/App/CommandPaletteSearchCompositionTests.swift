import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteSearchCompositionTests: XCTestCase {
    func testPendingFocusDoesNotRefocusAnAlreadyActiveEditor() async throws {
        let fixture = SearchCompositionFixture()
        defer { fixture.close() }
        let field = try await fixture.searchField()
        fixture.window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("query", replacementRange: NSRange(location: 0, length: 0))
        await fixture.settle()
        let selection = NSRange(location: 2, length: 0)
        editor.setSelectedRange(selection)
        fixture.window.reportsKeyWindow = true
        XCTAssertTrue(fixture.window.firstResponder === editor)
        fixture.window.fieldFocusRequests = 0
        let coordinator = try XCTUnwrap(field.delegate as? CommandPaletteSearchField.Coordinator)

        coordinator.focus(field, for: 999)
        await fixture.settle()

        XCTAssertEqual(fixture.window.fieldFocusRequests, 0)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
    }

    func testCurrentEditorPreservesCaretWhenCellValueIsStale() {
        let field = LaggingCellTextField()
        let prefix = "ask fixture Hello "
        field.editor.string = prefix
        let insertion = NSRange(location: prefix.utf16.count, length: 0)
        field.editor.setSelectedRange(insertion)
        XCTAssertNotEqual(field.stringValue, field.editor.string)

        CommandPaletteSearchField.synchronizeText(prefix, in: field)

        XCTAssertEqual(field.assignments, 0)
        XCTAssertEqual(field.editor.selectedRange(), insertion)
        field.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: field.editor.selectedRange())
        field.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(field.editor.string, prefix + "你")
    }

    func testExternalClearUpdatesEditorEvenWhenCellAlreadyMatches() {
        let field = LaggingCellTextField()
        field.editor.string = "ask fixture Hello"
        XCTAssertEqual(field.stringValue, "")

        CommandPaletteSearchField.synchronizeText("", in: field)

        XCTAssertEqual(field.assignments, 1)
        XCTAssertEqual(field.editor.string, "")
    }

    func testExternalUpdateDoesNotReplaceMarkedText() {
        let field = LaggingCellTextField()
        field.editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: 0, length: 0))

        CommandPaletteSearchField.synchronizeText("replacement", in: field)

        XCTAssertEqual(field.assignments, 0)
        XCTAssertTrue(field.editor.hasMarkedText())
        XCTAssertEqual(field.editor.string, "ni")
    }

    func testNativeMouseSendIsBlockedDuringCompositionAndUsesCommittedText() async throws {
        let fixture = SearchCompositionFixture()
        defer { fixture.close() }
        let field = try await fixture.searchField()
        fixture.window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(fixture.state.inputState.editor === editor)

        let prefix = "ask fixture Hello "
        editor.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
        await fixture.settle()
        try fixture.clickSend()
        await fixture.settle()
        XCTAssertEqual(fixture.state.submissions, [prefix], "The baseline click must hit the native SwiftUI Send button")
        fixture.state.submissions.removeAll()

        fixture.window.makeFirstResponder(field)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: prefix.utf16.count, length: 0))
        await fixture.settle()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(fixture.state.inputState.hasMarkedText)
        XCTAssertTrue(fixture.state.hasMarkedText)
        try fixture.clickSend()
        await fixture.settle()
        XCTAssertTrue(fixture.state.submissions.isEmpty, "A mouse click must not submit an unfinished candidate")

        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        await fixture.settle()
        XCTAssertFalse(fixture.state.inputState.hasMarkedText)
        XCTAssertFalse(fixture.state.hasMarkedText)
        XCTAssertEqual(fixture.state.text, prefix + "你")
        try fixture.clickSend()
        await fixture.settle()
        XCTAssertEqual(fixture.state.submissions, [prefix + "你"])
    }
}

/// Models a cell that has not committed its editor's latest value yet. Like AppKit,
/// assigning stringValue while editing replaces the text and selection.
@MainActor
private final class LaggingCellTextField: NSTextField {
    let editor = NSTextView(frame: .zero)
    private var committedText = ""
    var assignments = 0

    override func currentEditor() -> NSText? { editor }

    override var stringValue: String {
        get { committedText }
        set {
            assignments += 1
            committedText = newValue
            editor.string = newValue
            editor.selectAll(nil)
        }
    }
}

@MainActor
private final class SearchCompositionState: ObservableObject {
    @Published var text = ""
    @Published var hasMarkedText = false
    let inputState = CommandPaletteSearchInputState()
    var submissions: [String] = []
}

private struct SearchCompositionView: View {
    @ObservedObject var state: SearchCompositionState

    var body: some View {
        VStack {
            CommandPaletteSearchField(
                text: $state.text, placeholder: "Search", accessibilityLabel: "Search",
                accessibilityIdentifier: "composition-test.search", focusRequestID: 1,
                onCommand: { _ in }, preservesText: { $0.hasPrefix("ask fixture") },
                onMarkedTextChange: { state.hasMarkedText = $0 }, inputState: state.inputState
            )
            .frame(height: 30)
            Button("Send") { state.submissions.append(state.text) }
                .buttonStyle(.borderedProminent)
                .disabled(state.hasMarkedText || state.text.isEmpty)
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}

@MainActor
private final class SearchCompositionFixture {
    let state = SearchCompositionState()
    let window = FocusTrackingWindow(contentRect: NSRect(x: 100, y: 100, width: 450, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SearchCompositionView(state: state))
        window.makeKeyAndOrderFront(nil)
    }

    func searchField() async throws -> NSTextField {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0 ..< 60 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = window.contentView,
               let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: {
                   $0.accessibilityIdentifier() == "composition-test.search"
               }) { return field }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(nil as NSTextField?, "The native search field did not become available")
    }

    func clickSend() throws {
        // This fixture fixes its window and content size. The baseline assertion verifies the hit before testing IME.
        let point = NSPoint(x: 225, y: 110)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            NSApp.sendEvent(event)
        }
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class FocusTrackingWindow: NSWindow {
    var fieldFocusRequests = 0
    var reportsKeyWindow = false

    override var isKeyWindow: Bool { reportsKeyWindow || super.isKeyWindow }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextField { fieldFocusRequests += 1 }
        return super.makeFirstResponder(responder)
    }
}
