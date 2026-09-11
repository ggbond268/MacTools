import XCTest
@testable import AutoHideMenuBarPlugin

@MainActor
final class MenuBarAutoHideControllerTests: XCTestCase {
    func testControllerWritesBothComponentsForEveryMode() throws {
        for mode in MenuBarAutoHideMode.allCases {
            var desktop = false
            var fullScreenVisible = false
            let controller = MenuBarAutoHideController(access: .init(
                readDesktopAutoHide: { desktop },
                readVisibleInFullScreen: { fullScreenVisible },
                writeDesktopAutoHide: { desktop = $0 },
                writeVisibleInFullScreen: { fullScreenVisible = $0 }
            ))
            try controller.setMode(mode)
            XCTAssertEqual(try controller.read(), mode)
        }
    }

    func testControllerRestoresBothComponentsAfterPartialFailure() {
        var desktop = true
        var fullScreenVisible = true
        var shouldFailDesktopWrite = true
        let controller = MenuBarAutoHideController(access: .init(
            readDesktopAutoHide: { desktop },
            readVisibleInFullScreen: { fullScreenVisible },
            writeDesktopAutoHide: {
                if shouldFailDesktopWrite {
                    shouldFailDesktopWrite = false
                    throw NSError(domain: "test", code: 1)
                }
                desktop = $0
            },
            writeVisibleInFullScreen: { fullScreenVisible = $0 }
        ))
        XCTAssertThrowsError(try controller.setMode(.always))
        XCTAssertEqual(try controller.read(), .desktopOnly)
    }
}
