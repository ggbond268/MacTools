import XCTest
@testable import FanControlPlugin

@MainActor
final class FanControlSMCWriterTests: XCTestCase {
    func testNightlyUsesSeparateHelperInstallPathWithoutChangingStable() {
        let stablePath = "/Library/PrivilegedHelperTools/cc.ggbond.mactools.fan-control.smc-helper"
        for channel in [nil, "stable", "development", "unknown"] {
            XCTAssertEqual(FanControlSMCWriter(releaseChannel: channel).helperInstallPath, stablePath)
        }
        XCTAssertEqual(
            FanControlSMCWriter(releaseChannel: "nightly").helperInstallPath,
            stablePath + ".nightly"
        )
    }

    func testHelperPrivilegesRequireRootWheelAndSetuidExecutableMode() {
        let valid: [FileAttributeKey: Any] = [
            .ownerAccountID: NSNumber(value: 0),
            .groupOwnerAccountID: NSNumber(value: 0),
            .posixPermissions: NSNumber(value: 0o4755)
        ]

        XCTAssertTrue(FanControlSMCWriter.helperHasExpectedPrivileges(attributes: valid))

        for invalidAttributes in [
            attributes(from: valid, replacing: .ownerAccountID, with: 501),
            attributes(from: valid, replacing: .groupOwnerAccountID, with: 20),
            attributes(from: valid, replacing: .posixPermissions, with: 0o0755)
        ] {
            XCTAssertFalse(FanControlSMCWriter.helperHasExpectedPrivileges(attributes: invalidAttributes))
        }
    }

    private func attributes(
        from source: [FileAttributeKey: Any],
        replacing key: FileAttributeKey,
        with value: Int
    ) -> [FileAttributeKey: Any] {
        var result = source
        result[key] = NSNumber(value: value)
        return result
    }
}
