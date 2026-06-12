import XCTest
@testable import MacTools
@testable import HideNotchPlugin

final class HideNotchDisplayCatalogTests: XCTestCase {
    func testResolverUsesCurrentPlaceholderWhenCurrentDesktopUUIDIsEmpty() {
        let spaces = HideNotchManagedDisplaySpaceResolver.spaces(from: [
            "Current Space": [
                "uuid": "",
                "type": 0
            ],
            "Spaces": [
                [
                    "uuid": "",
                    "type": 0
                ]
            ]
        ])

        XCTAssertEqual(
            spaces,
            [
                HideNotchDisplaySpace(
                    identifier: HideNotchDisplaySpace.currentPlaceholderIdentifier,
                    isCurrent: true
                )
            ]
        )
    }

    func testNotchHeightUsesAuxHeightWhenMenuBarIsShorter() {
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: 32,
                auxRightHeight: 32,
                menuBarHeight: 30
            ),
            32
        )
    }

    func testNotchHeightIgnoresTallerMenuBarWhenAuxHeightExists() {
        // Regression: the old max(menuBar, aux) logic returned 40 here, which
        // made the mask overflow below the physical notch.
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: 32,
                auxRightHeight: 32,
                menuBarHeight: 40
            ),
            32
        )
    }

    func testNotchHeightUsesTallerAuxSideWhenSidesDiffer() {
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: 28,
                auxRightHeight: 32,
                menuBarHeight: 24
            ),
            32
        )
    }

    func testNotchHeightFallsBackToMenuBarWhenAuxHeightsAreZero() {
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: 0,
                auxRightHeight: 0,
                menuBarHeight: 24
            ),
            24
        )
    }

    func testNotchHeightIsZeroWhenAllInputsAreZero() {
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: 0,
                auxRightHeight: 0,
                menuBarHeight: 0
            ),
            0
        )
    }

    func testNotchHeightRejectsNonFiniteInputs() {
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: .nan,
                auxRightHeight: .infinity,
                menuBarHeight: -1
            ),
            0
        )
    }

    func testNotchHeightKeepsValidSideWhenOtherSideIsNaN() {
        // max(.nan, 32) returns .nan in Swift, so a NaN left side must be
        // sanitized before max() or it would discard the valid right side
        // and wrongly fall back to the menu bar estimate.
        XCTAssertEqual(
            SystemHideNotchDisplayCatalog.notchHeight(
                auxLeftHeight: .nan,
                auxRightHeight: 32,
                menuBarHeight: 24
            ),
            32
        )
    }

    func testResolverFiltersOutNonDesktopSpaces() {
        let spaces = HideNotchManagedDisplaySpaceResolver.spaces(from: [
            "Current Space": [
                "uuid": "",
                "type": 0
            ],
            "Spaces": [
                [
                    "uuid": "",
                    "type": 0
                ],
                [
                    "uuid": "E511762E-A085-4DFB-AF2E-B8F5E83A7952",
                    "type": 4,
                    "WallSpace": [
                        "uuid": "48CC1451-CDC2-4890-91F0-A03908F06252",
                        "type": 6
                    ]
                ],
                [
                    "uuid": "DESKTOP-2",
                    "type": 0
                ]
            ]
        ])

        XCTAssertEqual(
            spaces,
            [
                HideNotchDisplaySpace(
                    identifier: HideNotchDisplaySpace.currentPlaceholderIdentifier,
                    isCurrent: true
                ),
                HideNotchDisplaySpace(
                    identifier: "DESKTOP-2",
                    isCurrent: false
                )
            ]
        )
    }
}
