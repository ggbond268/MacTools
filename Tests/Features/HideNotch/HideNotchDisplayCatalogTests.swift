import XCTest
@testable import MacTools

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
