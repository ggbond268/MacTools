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

    func testOptionTitleMarksScaledHiDPIMode() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(for: makeMode(modeId: 3, width: 3008, height: 1692)),
            "3008×1692 (HiDPI)"
        )
    }

    func testOptionTitleMarksHiDPIMode() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(
                for: makeMode(
                    modeId: 4,
                    width: 3200,
                    height: 1800,
                    pixelWidth: 6400,
                    pixelHeight: 3600,
                    isHiDPI: true
                )
            ),
            "3200×1800 (HiDPI)"
        )
    }

    func testOptionTitleMarksLoDPIMode() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(
                for: makeMode(
                    modeId: 5,
                    width: 4096,
                    height: 2304,
                    pixelWidth: 4096,
                    pixelHeight: 2304,
                    isHiDPI: false
                )
            ),
            "4096×2304 (LoDPI)"
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

    func testDedupeModesPreservesCurrentModeOverHigherRefreshDuplicate() {
        let modes = [
            makeMode(modeId: 40, width: 1512, height: 982, refreshRate: 60, isCurrent: true),
            makeMode(modeId: 41, width: 1512, height: 982, refreshRate: 120)
        ]

        XCTAssertEqual(DisplayResolutionController.deduplicateModes(modes).map(\.modeId), [40])
    }

    func testDedupeModesPrefersHigherRefreshWhenNeitherDuplicateIsCurrent() {
        let modes = [
            makeMode(modeId: 50, width: 1512, height: 982, refreshRate: 60),
            makeMode(modeId: 51, width: 1512, height: 982, refreshRate: 120)
        ]

        XCTAssertEqual(DisplayResolutionController.deduplicateModes(modes).map(\.modeId), [51])
    }

    func testDedupeModesPrefersHiDPIOverLoDPIForSameLogicalResolution() {
        let modes = [
            makeMode(modeId: 60, width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, isHiDPI: false),
            makeMode(modeId: 61, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, isHiDPI: true)
        ]

        XCTAssertEqual(DisplayResolutionController.deduplicateModes(modes).map(\.modeId), [61])
    }

    func testDedupeModesPreservesCurrentLoDPIOverHiDPIDuplicate() {
        let modes = [
            makeMode(modeId: 70, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, isHiDPI: true),
            makeMode(modeId: 71, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, isHiDPI: false, isCurrent: true)
        ]

        XCTAssertEqual(DisplayResolutionController.deduplicateModes(modes).map(\.modeId), [71])
    }

    func testSortModesOrdersByLogicalResolutionDescending() {
        let modes = [
            makeMode(modeId: 80, width: 3200, height: 1800, pixelWidth: 6400, pixelHeight: 3600),
            makeMode(modeId: 81, width: 5120, height: 2880, pixelWidth: 5120, pixelHeight: 2880, isHiDPI: false, isNative: true),
            makeMode(modeId: 82, width: 4096, height: 2304, pixelWidth: 4096, pixelHeight: 2304, isHiDPI: false),
            makeMode(modeId: 83, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, isNative: true)
        ]

        XCTAssertEqual(
            DisplayResolutionController.sortModes(modes).map(\.modeId),
            [81, 82, 80, 83]
        )
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
