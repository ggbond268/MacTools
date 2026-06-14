import XCTest
@testable import MacTools
@testable import DeviceBatteryPlugin

/// Coverage for the macOS 27 beta `log show` fix. On 26A5353q passing
/// `--process bluetoothd` together with `--predicate …` makes `log` drop the
/// predicate and emit the unfiltered firehose (≈4024 lines vs 1 with the
/// predicate alone), causing missing Bluetooth battery readings and a CPU
/// spike. The fix drops `--process`/`bluetoothd`; the predicate already pins
/// `subsystem == "com.apple.bluetooth"`, so it is sufficient on every macOS.
final class DeviceBatteryBluetoothLogArgumentsTests: XCTestCase {
    private let predicate = #"subsystem == "com.apple.bluetooth" AND category == "CBPowerSource""#

    func testArgumentsDoNotIncludeProcessFilter() {
        let arguments = DeviceBatterySampler.bluetoothPowerLogShowArguments(
            lookback: "1m",
            predicate: predicate
        )

        XCTAssertFalse(arguments.contains("--process"), "--process drops the predicate on the beta")
        XCTAssertFalse(arguments.contains("bluetoothd"))
    }

    func testArgumentsRetainPredicateAndLookback() {
        let arguments = DeviceBatterySampler.bluetoothPowerLogShowArguments(
            lookback: "1m",
            predicate: predicate
        )

        XCTAssertEqual(arguments.first, "show")
        XCTAssertTrue(arguments.contains("--predicate"))

        let predicateIndex = arguments.firstIndex(of: "--predicate")
        let lookbackIndex = arguments.firstIndex(of: "--last")
        XCTAssertNotNil(predicateIndex)
        XCTAssertNotNil(lookbackIndex)
        // Each flag is immediately followed by its value.
        XCTAssertEqual(arguments[predicateIndex! + 1], predicate)
        XCTAssertEqual(arguments[lookbackIndex! + 1], "1m")
    }

    func testExactArgumentVector() {
        // Lock the full vector so a future `--process` re-introduction is caught.
        XCTAssertEqual(
            DeviceBatterySampler.bluetoothPowerLogShowArguments(lookback: "1m", predicate: predicate),
            [
                "show",
                "--info",
                "--last",
                "1m",
                "--style",
                "compact",
                "--predicate",
                predicate
            ]
        )
    }
}
