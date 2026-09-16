import XCTest
@testable import AppUninstallerPlugin

final class AppUninstallerFullDiskAccessProbeTests: XCTestCase {
    private let home = "/Users/app-uninstaller-tests"

    func testUsesSafariBookmarksWhenUserTCCDatabaseIsMissing() {
        var attemptedPaths: [String] = []
        let granted = AppUninstallerFullDiskAccessProbe.hasAccess(homeDirectory: home) { path in
            attemptedPaths.append(path)
            return path == home + "/Library/Safari/Bookmarks.plist"
        }

        XCTAssertTrue(granted)
        XCTAssertEqual(attemptedPaths, [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist"
        ])
    }

    func testStopsAfterFirstProtectedFileOpens() {
        var attemptedPaths: [String] = []
        let granted = AppUninstallerFullDiskAccessProbe.hasAccess(homeDirectory: home) { path in
            attemptedPaths.append(path)
            return true
        }

        XCTAssertTrue(granted)
        XCTAssertEqual(attemptedPaths, [home + "/Library/Application Support/com.apple.TCC/TCC.db"])
    }

    func testDoesNotAssumeAccessWhenNeitherProtectedFileOpens() {
        let granted = AppUninstallerFullDiskAccessProbe.hasAccess(homeDirectory: home) { _ in false }

        XCTAssertFalse(granted)
    }
}
