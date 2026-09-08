import XCTest
@testable import MacTools

final class ShortcutSettingsPresentationTests: XCTestCase {
    func testMixedPluginGroupsHideOnlyNeutralAssignmentBadges() {
        XCTAssertFalse(ActionShortcutStatusBadgePolicy.shouldShow(
            .assigned,
            hidesNeutralStatus: true
        ))
        XCTAssertFalse(ActionShortcutStatusBadgePolicy.shouldShow(
            .unassigned,
            hidesNeutralStatus: true
        ))
        XCTAssertTrue(ActionShortcutStatusBadgePolicy.shouldShow(
            .conflicted("Already used"),
            hidesNeutralStatus: true
        ))
        XCTAssertTrue(ActionShortcutStatusBadgePolicy.shouldShow(
            .unavailable("Unavailable"),
            hidesNeutralStatus: true
        ))
    }

    func testActionsAndShortcutsCatalogKeepsAllStatusBadges() {
        for status: ActionShortcutCatalogStatus in [
            .assigned,
            .unassigned,
            .conflicted("Already used"),
            .unavailable("Unavailable"),
        ] {
            XCTAssertTrue(ActionShortcutStatusBadgePolicy.shouldShow(
                status,
                hidesNeutralStatus: false
            ))
        }
    }
}
