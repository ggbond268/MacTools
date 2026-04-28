import XCTest
@testable import MacTools

final class SystemStatusSamplerTests: XCTestCase {
    func testCPUUsageCalculatorUsesPositiveTickDeltas() throws {
        let previous = SystemStatusCPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = SystemStatusCPUTicks(user: 150, system: 75, idle: 925, nice: 0)

        let usage = try XCTUnwrap(SystemStatusCPUUsageCalculator.usage(current: current, previous: previous))

        XCTAssertEqual(usage, 0.5, accuracy: 0.0001)
    }

    func testCPUUsageCalculatorReturnsNilForNoElapsedTicks() {
        let ticks = SystemStatusCPUTicks(user: 100, system: 50, idle: 850, nice: 0)

        XCTAssertNil(SystemStatusCPUUsageCalculator.usage(current: ticks, previous: ticks))
    }

    func testNetworkRateCalculatorClampsNegativeDeltas() {
        let previous = SystemStatusNetworkCounter(
            key: "en0",
            displayName: "en0",
            receivedBytes: 2_000,
            sentBytes: 2_000,
            ipAddress: "192.168.1.2",
            isUp: true
        )
        let current = SystemStatusNetworkCounter(
            key: "en0",
            displayName: "en0",
            receivedBytes: 1_500,
            sentBytes: 2_400,
            ipAddress: "192.168.1.2",
            isUp: true
        )

        let rate = SystemStatusNetworkRateCalculator.rate(
            current: current,
            previous: previous,
            elapsedSeconds: 2
        )

        XCTAssertEqual(rate?.downloadBytesPerSecond, 0)
        XCTAssertEqual(rate?.uploadBytesPerSecond, 200)
    }

    func testNetworkRateCalculatorReturnsNilForZeroElapsedTime() {
        let counter = SystemStatusNetworkCounter(
            key: "en0",
            displayName: "en0",
            receivedBytes: 2_000,
            sentBytes: 2_000,
            ipAddress: nil,
            isUp: true
        )

        XCTAssertNil(
            SystemStatusNetworkRateCalculator.rate(
                current: counter,
                previous: counter,
                elapsedSeconds: 0
            )
        )
    }

    func testProcessParserSortsByCPUThenMemoryThenPIDAndLimits() {
        let output = """
          42   8.5  1.0 /Applications/Alpha.app/Contents/MacOS/Alpha
           7  12.0  2.0 /usr/bin/beta
           9  12.0  5.0 /usr/bin/gamma
           6  12.0  5.0 /usr/bin/delta
          11   1.0  9.0 /usr/bin/epsilon
        """

        let processes = SystemStatusProcessParser.parsePSOutput(output, limit: 3)

        XCTAssertEqual(processes.map(\.pid), [6, 9, 7])
        XCTAssertEqual(processes.map(\.displayName), ["delta", "gamma", "beta"])
        XCTAssertEqual(processes[0].cpuPercent, 12)
        XCTAssertEqual(processes[0].memoryPercent, 5)
    }

    func testFormatterOutputsExpectedValues() {
        XCTAssertEqual(SystemStatusFormatter.percent(0.425), "43%")
        XCTAssertEqual(SystemStatusFormatter.wholePercent(12.34, fractionDigits: 1), "12.3%")
        XCTAssertEqual(SystemStatusFormatter.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(SystemStatusFormatter.speed(1_048_576), "1.0 MB/s")
        XCTAssertEqual(SystemStatusFormatter.timeRemaining(minutes: 65), "1h 5m")
        XCTAssertEqual(SystemStatusFormatter.timeRemaining(minutes: nil), "估算中")
    }
}
