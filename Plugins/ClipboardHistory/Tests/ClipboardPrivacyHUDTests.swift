import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardPrivacyHUDTests: XCTestCase {
    private let localization = PluginLocalization(bundle: .main)

    func testHUDContentDistinguishesPendingSuccessAndFailureStates() {
        XCTAssertEqual(
            ClipboardPrivacyHUDContent.armed(
                secondsRemaining: 15,
                localization: localization
            ),
            ClipboardPrivacyHUDContent(
                title: "下次复制不会保存 · 15 秒",
                systemImage: "eye.slash.fill",
                tone: .neutral
            )
        )
        XCTAssertEqual(ClipboardPrivacyHUDContent.ignored(localization: localization).tone, .success)
        XCTAssertEqual(
            ClipboardPrivacyHUDContent.privateCopySucceeded(localization: localization).title,
            "已私密复制"
        )
        XCTAssertEqual(ClipboardPrivacyHUDContent.failure("私密复制失败").tone, .failure)
    }

    func testHUDCountdownNeverDisplaysNegativeSeconds() {
        XCTAssertEqual(
            ClipboardPrivacyHUDContent.armed(
                secondsRemaining: -1,
                localization: localization
            ).title,
            "下次复制不会保存 · 0 秒"
        )
    }

    func testHUDPanelIsClickThroughAndCannotTakeApplicationFocus() {
        let panel = ClipboardPrivacyHUDController.makePanel()

        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        panel.close()
    }
}
