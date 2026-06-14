import XCTest
@testable import MacTools
@testable import DisplayBrightnessPlugin

/// Coverage for the macOS 27 beta gamma-capacity fix path. On 26A5353q the old
/// `CGGetDisplayTransferByTable(id, 0, nil, nil, nil, &count)` size-query idiom
/// returns 1001 (not .success) on every display, which silently collapsed the
/// init capacity gate and the original-transfer-table load (and therefore the
/// gamma restore-on-exit chain). The fix queries `CGDisplayGammaTableCapacity`
/// instead; this exercises the pure capacity gate that both call sites now use.
/// The load/restore chain itself is covered by
/// `GammaBrightnessBackendRestoreTests`.
final class GammaBrightnessBackendCapacityTests: XCTestCase {
    func testPositiveCapacityIsControllable() {
        // Beta-observed capacity is 1024; any positive capacity must be usable.
        XCTAssertTrue(GammaBrightnessBackend.gammaTableCapacityIsControllable(1024))
        XCTAssertTrue(GammaBrightnessBackend.gammaTableCapacityIsControllable(256))
        XCTAssertTrue(GammaBrightnessBackend.gammaTableCapacityIsControllable(1))
    }

    func testZeroCapacityIsNotControllable() {
        // A zero capacity means no gamma table is available → reject so the
        // backend builder skips gamma and falls through to the next link.
        XCTAssertFalse(GammaBrightnessBackend.gammaTableCapacityIsControllable(0))
    }
}
