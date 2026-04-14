import XCTest
@testable import MacTools

final class DisplayResolutionPluginTests: XCTestCase {
    func testParseDisplayIDValidPrefix() {
        XCTAssertEqual(DisplayResolutionPlugin.parseDisplayID(from: "display.1"), 1)
    }

    func testParseDisplayIDInvalidFormat() {
        XCTAssertNil(DisplayResolutionPlugin.parseDisplayID(from: "display.abc"))
    }

    func testParseDisplayIDWrongPrefix() {
        XCTAssertNil(DisplayResolutionPlugin.parseDisplayID(from: "foo.1"))
    }

    func testOptionTitleMarksNative() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(for: makeMode(modeId: 1, width: 3008, height: 1692, isNative: true)),
            "3008×1692 (原生)"
        )
    }

    func testOptionTitleMarksDefault() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(for: makeMode(modeId: 2, width: 3008, height: 1692, isDefault: true)),
            "3008×1692 (默认)"
        )
    }

    func testOptionTitleLeavesScaledModeUndecorated() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(for: makeMode(modeId: 3, width: 3008, height: 1692)),
            "3008×1692"
        )
    }

    func testVisibleModesDropsOffRatioWhenNotCurrent() {
        let modes = [
            makeMode(modeId: 10, width: 1728, height: 1117, isNative: true),
            makeMode(modeId: 11, width: 1512, height: 982)
        ]

        XCTAssertEqual(DisplayResolutionPlugin.visibleModes(modes).map(\.modeId), [10])
    }

    func testVisibleModesKeepsCurrentEvenWhenOffRatio() {
        let modes = [
            makeMode(modeId: 20, width: 1728, height: 1117, isNative: true),
            makeMode(modeId: 21, width: 1440, height: 900, isCurrent: true)
        ]

        XCTAssertEqual(Set(DisplayResolutionPlugin.visibleModes(modes).map(\.modeId)), Set([20, 21]))
    }

    func testVisibleModesEmptyInput() {
        XCTAssertEqual(DisplayResolutionPlugin.visibleModes([]), [])
    }

    func testDisplayResolutionInfoEquatableByModeId() {
        XCTAssertEqual(
            makeMode(modeId: 99, width: 3008, height: 1692),
            makeMode(modeId: 99, width: 1512, height: 982, isHiDPI: false)
        )
    }

    private func makeMode(
        modeId: Int32,
        width: Int,
        height: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        refreshRate: Double = 60,
        isHiDPI: Bool = true,
        isNative: Bool = false,
        isDefault: Bool = false,
        isCurrent: Bool = false
    ) -> DisplayResolutionInfo {
        DisplayResolutionInfo(
            modeId: modeId,
            width: width,
            height: height,
            pixelWidth: pixelWidth ?? width * 2,
            pixelHeight: pixelHeight ?? height * 2,
            refreshRate: refreshRate,
            isHiDPI: isHiDPI,
            isNative: isNative,
            isDefault: isDefault,
            isCurrent: isCurrent
        )
    }
}
