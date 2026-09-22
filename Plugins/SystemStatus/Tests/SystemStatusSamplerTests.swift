import XCTest
@testable import MacTools
@testable import SystemStatusPlugin

final class SystemStatusSamplerTests: XCTestCase {
    func testCommandRunnerDrainsOutputLargerThanPipeBuffer() async throws {
        let lineCount = 100_000
        let commandResult = await SystemStatusCommandRunner.run(
            path: "/usr/bin/jot",
            arguments: ["-b", "x", String(lineCount)],
            timeout: 2
        )
        let result = try XCTUnwrap(commandResult)

        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, String(repeating: "x\n", count: lineCount))
        XCTAssertEqual(result.standardError, "")
    }

    func testCommandRunnerTerminatesTimedOutProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let commandResult = await SystemStatusCommandRunner.run(
            path: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )
        let result = try XCTUnwrap(commandResult)

        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testBatteryTemperatureUsesNestedAndVirtualRegistryFallbacks() throws {
        XCTAssertEqual(
            try XCTUnwrap(SystemStatusSampler.batteryTemperatureCelsius(rawValues: [nil, 3_589, 3_200])),
            35.89,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SystemStatusSampler.batteryTemperatureCelsius(rawValues: [12_000, 3_200])),
            32,
            accuracy: 0.001
        )
        XCTAssertNil(SystemStatusSampler.batteryTemperatureCelsius(rawValues: [nil, 12_000]))
    }

    func testCPUUsageCalculatorUsesPositiveTickDeltas() throws {
        let usage = try XCTUnwrap(SystemStatusCPUUsageCalculator.usage(
            current: SystemStatusCPUTicks(user: 150, system: 75, idle: 925, nice: 0),
            previous: SystemStatusCPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        ))

        XCTAssertEqual(usage, 0.5, accuracy: 0.0001)
    }

    func testPowerCalculatorUsesEnergyDeltaOverElapsedTime() throws {
        let watts = try XCTUnwrap(SystemStatusPowerCalculator.watts(
            current: SystemStatusPowerEnergySample(joules: 105, date: Date(timeIntervalSince1970: 1_002)),
            previous: SystemStatusPowerEnergySample(joules: 100, date: Date(timeIntervalSince1970: 1_000))
        ))

        XCTAssertEqual(watts, 2.5, accuracy: 0.0001)
    }

    func testNetworkRateCalculatorDifferentiatesCountersByElapsedTime() {
        let rate = SystemStatusNetworkRateCalculator.rate(
            current: SystemStatusNetworkCounter(
                key: "iflist2:en0",
                displayName: "en0",
                receivedBytes: 16_000,
                sentBytes: 27_500,
                ipAddress: "192.168.1.2",
                isUp: true
            ),
            previous: SystemStatusNetworkCounter(
                key: "iflist2:en0",
                displayName: "en0",
                receivedBytes: 10_000,
                sentBytes: 20_000,
                ipAddress: "192.168.1.2",
                isUp: true
            ),
            elapsedSeconds: 3
        )

        XCTAssertEqual(rate?.downloadBytesPerSecond, 2_000)
        XCTAssertEqual(rate?.uploadBytesPerSecond, 2_500)
    }

    func testDiskIORateCalculatorDifferentiatesCountersByElapsedTime() {
        let rate = SystemStatusDiskIORateCalculator.rate(
            current: SystemStatusDiskIOCounter(readBytes: 16_000, writeBytes: 27_500),
            previous: SystemStatusDiskIOCounter(readBytes: 10_000, writeBytes: 20_000),
            elapsedSeconds: 3
        )

        XCTAssertEqual(rate?.readBytesPerSecond, 2_000)
        XCTAssertEqual(rate?.writeBytesPerSecond, 2_500)
    }

    func testGPUUtilizationPrefersDeviceUtilizationOverPipelineCounters() throws {
        let usage = try XCTUnwrap(SystemStatusSampler.gpuUtilization(from: [
            "Device Utilization %": 18,
            "Renderer Utilization %": 100,
            "Tiler Utilization %": 100
        ]))

        XCTAssertEqual(usage, 0.18, accuracy: 0.0001)
    }

    func testGPUUtilizationFallsBackToGPUActivity() throws {
        let usage = try XCTUnwrap(SystemStatusSampler.gpuUtilization(from: [
            "GPU Activity(%)": 42,
            "Renderer Utilization %": 100,
            "Tiler Utilization %": 100
        ]))

        XCTAssertEqual(usage, 0.42, accuracy: 0.0001)
    }

    func testBatteryHealthPercentPrefersNominalChargeCapacity() {
        let health = SystemStatusSampler.batteryHealthPercent(
            designCapacity: 10_000,
            nominalChargeCapacity: 8_300,
            appleRawMaxCapacity: 7_800
        )

        XCTAssertEqual(health, 83)
    }

    func testBatteryPowerNormalizerUsesSignedBatteryPowerMilliwatts() throws {
        let dischargingWatts = try XCTUnwrap(
            SystemStatusBatteryPowerNormalizer.telemetryWatts(fromRawMilliwatts: 13_654)
        )
        let chargingWatts = try XCTUnwrap(
            SystemStatusBatteryPowerNormalizer.telemetryWatts(fromRawMilliwatts: -12_345)
        )

        XCTAssertEqual(dischargingWatts, 13.654, accuracy: 0.001)
        XCTAssertEqual(chargingWatts, -12.345, accuracy: 0.001)
    }

    func testProcessParserSortsByCPUThenMemoryThenPIDAndLimits() {
        let output = """
          42   8.5  1.0  10240 /Applications/Alpha.app/Contents/MacOS/Alpha
           7  12.0  2.0  20480 /usr/bin/beta
           9  12.0  5.0  40960 /usr/bin/gamma
           6  12.0  5.0  51200 /usr/bin/delta
        """

        let processes = SystemStatusProcessParser.parsePSOutput(output, limit: 3)

        XCTAssertEqual(processes.map(\.pid), [6, 9, 7])
        XCTAssertEqual(processes.map(\.displayName), ["delta", "gamma", "beta"])
    }

}
