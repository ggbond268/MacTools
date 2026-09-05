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
        XCTAssertEqual(ClipboardPrivacyHUDContent.success("已导出").tone, .success)
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

    func testHUDAnnouncesEachNewPresentationButNotDismissal() async {
        var announcements: [String] = []
        var uptime: TimeInterval = 100
        let controller = ClipboardPrivacyHUDController(
            transientDuration: .seconds(10),
            systemUptime: { uptime },
            screens: { [] },
            announce: { announcements.append($0) }
        )

        controller.handleSuppressionEvent(.armed(mode: .ignoreNextCopy, timeout: 15))
        XCTAssertEqual(announcements, ["下次复制不会保存 · 15 秒"])

        uptime = 101
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(announcements, ["下次复制不会保存 · 15 秒"])

        controller.handleSuppressionEvent(.consumed(mode: .privateCopy))
        controller.showSuccess("已导出")
        controller.showFailure("私密复制失败")
        controller.dismiss()
        XCTAssertEqual(announcements, [
            "下次复制不会保存 · 15 秒",
            "已私密复制",
            "已导出",
            "私密复制失败",
        ])
    }
}
