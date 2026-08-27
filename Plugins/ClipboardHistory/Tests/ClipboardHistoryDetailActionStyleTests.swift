import AppKit
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryDetailActionStyleTests: XCTestCase {
    func testPrimaryAndIconActionsHaveEqualHitTargetHeight() {
        let share = NSHostingView(rootView: Button {} label: {
            Image(systemName: "square.and.arrow.up")
        }.buttonStyle(ClipboardHistoryDetailActionStyle()).fixedSize())
        let paste = NSHostingView(rootView: Button("Paste") {}
            .buttonStyle(ClipboardHistoryDetailActionStyle(isPrimary: true)).fixedSize())
        let edit = NSHostingView(rootView: Button {} label: {
            Image(systemName: "pencil")
        }.buttonStyle(ClipboardHistoryDetailActionStyle()).fixedSize())
        XCTAssertEqual(share.fittingSize.height, 36, accuracy: 0.5)
        XCTAssertEqual(paste.fittingSize.height, share.fittingSize.height, accuracy: 0.5)
        XCTAssertEqual(edit.fittingSize.height, share.fittingSize.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(share.fittingSize.width, 36)
        XCTAssertGreaterThanOrEqual(edit.fittingSize.width, 36)
    }
}
