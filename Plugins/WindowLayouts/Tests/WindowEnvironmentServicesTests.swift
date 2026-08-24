import CoreGraphics
import XCTest
@testable import WindowLayoutsPlugin

@MainActor
final class StageManagerSafeAreaProviderTests: XCTestCase {
    func testRemovesVisibleStageStripFromLeftEdge() {
        let stripBounds = CGRect(x: 0, y: 0, width: 112, height: 900)
            .dictionaryRepresentation as NSDictionary as! [String: Any]
        let provider = SystemStageManagerSafeAreaProvider(
            stageManagerEnabled: { true },
            windowInfo: {
                [[
                    kCGWindowOwnerName as String: "Dock",
                    kCGWindowBounds as String: stripBounds
                ]]
            }
        )
        let screen = WindowScreen(
            id: "display:1",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )

        XCTAssertEqual(
            provider.safeVisibleFrame(for: screen),
            CGRect(x: 112, y: 24, width: 1328, height: 876)
        )
    }

    func testLeavesVisibleFrameUnchangedWhenStageManagerIsDisabled() {
        let provider = SystemStageManagerSafeAreaProvider(
            stageManagerEnabled: { false },
            windowInfo: { XCTFail("Window list should not be read"); return [] }
        )
        let screen = WindowScreen(
            id: "display:1",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )

        XCTAssertEqual(provider.safeVisibleFrame(for: screen), screen.visibleFrame)
    }
}
