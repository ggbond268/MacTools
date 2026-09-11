import XCTest
@testable import BatteryChargeLimitPlugin

@MainActor
final class BatteryChargeLimitWriterTests: XCTestCase {
    func testNightlyUsesSeparateHelperInstallPathWithoutChangingStable() {
        let stablePath = "/Library/PrivilegedHelperTools/cc.ggbond.mactools.battery-charge-limit.smc-helper"
        for channel in [nil, "stable", "development", "unknown"] {
            XCTAssertEqual(BatteryChargeLimitWriter(releaseChannel: channel).helperInstallPath, stablePath)
        }
        XCTAssertEqual(
            BatteryChargeLimitWriter(releaseChannel: "nightly").helperInstallPath,
            stablePath + ".nightly"
        )
    }
}
