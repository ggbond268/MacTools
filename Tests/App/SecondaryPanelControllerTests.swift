import AppKit
import XCTest
@testable import MacTools

@MainActor
final class SecondaryPanelControllerTests: XCTestCase {
    func testInternalFocusTransferPreservesDetailUntilHostCloses() {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let controller = SecondaryPanelController()
        var dismissals = 0
        controller.onHostWindowDismissRequest = { dismissals += 1 }
        controller.setHostWindow(window)
        defer { controller.setHostWindow(nil) }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(dismissals, 0)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(dismissals, 1)
    }
}
