import XCTest
@testable import MacTools
@testable import SystemStatusPlugin

final class SystemStatusSamplerTests: XCTestCase {
    func testDetailStatisticsUseEveryVisibleReadingRegardlessOfDrawingBudget() {
        let history = (0..<600).map { index -> SystemStatusHistoryPoint in
            let cpu: Double = index == 1 ? 1 : 0
            let download: UInt64 = index % 5 == 4 ? 100 : 0
            return SystemStatusHistoryPoint(
                timestamp: TimeInterval(index * 3),
                cpuUsage: cpu,
                networkDownloadBytesPerSecond: download
            )
        }
        for limit in [2, 120, 600] {
            let network = SystemStatusMetricDetailChartData(
                history: history, kind: .network, range: .thirtyMinutes, sampleLimit: limit
            )
            XCTAssertEqual(network.statistics.minimum, 0)
            XCTAssertEqual(network.statistics.average, 20)
            XCTAssertEqual(network.statistics.maximum, 100)
            XCTAssertEqual(network.statistics.count, 600)
            XCTAssertLessThanOrEqual(network.rateSamples.count, limit)

            let cpu = SystemStatusMetricDetailChartData(
                history: history, kind: .cpu, range: .thirtyMinutes, sampleLimit: limit
            )
            XCTAssertEqual(cpu.statistics.minimum, 0)
            XCTAssertEqual(cpu.statistics.maximum, 100)
            XCTAssertEqual(cpu.statistics.average, 100.0 / 600)
        }
    }

    func testStatisticsExcludeUnknownPercentageReadingsAndOutOfRangeHistory() {
        let history = [
            SystemStatusHistoryPoint(timestamp: 0, cpuUsage: 1),
            SystemStatusHistoryPoint(timestamp: 2_000),
            SystemStatusHistoryPoint(timestamp: 2_001, cpuUsage: 0.2),
            SystemStatusHistoryPoint(timestamp: 2_002, cpuUsage: 0.4),
        ]
        let data = SystemStatusMetricDetailChartData(history: history, kind: .cpu, range: .thirtyMinutes)
        XCTAssertEqual(data.statistics.count, 2)
        XCTAssertEqual(data.statistics.minimum, 20)
        XCTAssertEqual(data.statistics.average, 30)
        XCTAssertEqual(data.statistics.maximum, 40)
        let empty = SystemStatusMetricDetailChartData(history: [], kind: .cpu, range: .thirtyMinutes)
        XCTAssertNil(empty.statistics.minimum)
        XCTAssertNil(empty.statistics.average)
        XCTAssertNil(empty.statistics.maximum)
    }

    func testRateDownsamplingRetainsBothSeriesWithinTheOriginalBudget() {
        let samples = (0..<600).map { index -> SystemStatusHUDRateChartSample in
            let first: Double = index % 5 == 0 ? 1_000 : 0
            let second: Double = index % 5 == 1 ? 100 : 0
            return SystemStatusHUDRateChartSample(
                timestamp: TimeInterval(index * 3),
                firstValue: first,
                secondValue: second
            )
        }
        for limit in [2, 3, 5, 120] {
            let reduced = SystemStatusHUDDualLineChart.downsamplePeakSamples(samples, limit: limit)
            XCTAssertLessThanOrEqual(reduced.count, limit)
            XCTAssertEqual(reduced.map(\.firstValue).max(), 1_000)
            XCTAssertEqual(reduced.map(\.secondValue).max(), 100)
            XCTAssertEqual(reduced.map(\.timestamp), reduced.map(\.timestamp).sorted())
            XCTAssertEqual(Set(reduced.map(\.timestamp)).count, reduced.count)
            XCTAssertTrue(reduced.allSatisfy(samples.contains), "Do not invent paired values or timestamps")
        }
        XCTAssertTrue(SystemStatusHUDDualLineChart.downsamplePeakSamples(samples, limit: 0).isEmpty)
        XCTAssertEqual(SystemStatusHUDDualLineChart.downsamplePeakSamples(samples, limit: 1).count, 1)
        XCTAssertEqual(SystemStatusHUDDualLineChart.downsamplePeakSamples([], limit: 120), [])
    }

    func testPinnedReadingSurvivesResamplingAndExpiresWithTheVisibleRange() {
        let reading = SystemStatusChartSelection.Reading(timestamp: 90, values: [78, 12])
        var selection = SystemStatusChartSelection()
        selection.toggle(reading)
        // The next array need not contain timestamp 90: a pin owns the original reading.
        let updatedTimestamps = (0..<120).map { TimeInterval($0 * 3 + 3) }
        selection.expire(outside: SystemStatusHUDChartGeometry.timeRange(timestamps: updatedTimestamps))
        XCTAssertEqual(selection.pinned, reading)
        selection.expire(outside: 91...400)
        XCTAssertNil(selection.pinned)
        selection.toggle(reading)
        selection.toggle(.init(timestamp: 90, values: [0, 0]))
        XCTAssertNil(selection.pinned, "Clicking the same timestamp unpins even if its value changed")
        selection.toggle(reading)
        selection.expire(outside: nil)
        XCTAssertNil(selection.pinned)
    }

    func testNetworkChartDownsamplesWithBucketPeaks() {
        XCTAssertEqual(
            SystemStatusHUDDualLineChart.downsamplePeaks([1, 90, 3, 4], limit: 2),
            [90, 4]
        )
    }

    func testRateChartDownsamplingPreservesPeakTimestampAndPairedValues() {
        let samples = [
            SystemStatusHUDRateChartSample(timestamp: 0, firstValue: 1, secondValue: 2),
            SystemStatusHUDRateChartSample(timestamp: 300, firstValue: 90, secondValue: 5),
            SystemStatusHUDRateChartSample(timestamp: 600, firstValue: 3, secondValue: 100),
            SystemStatusHUDRateChartSample(timestamp: 603, firstValue: 4, secondValue: 4),
        ]

        XCTAssertEqual(
            SystemStatusHUDDualLineChart.downsamplePeakSamples(samples, limit: 2),
            [samples[1], samples[2]]
        )
    }

    func testSingleLineChartDownsamplingPreservesSelectedRangeEndpoints() {
        let samples = (0..<10).map {
            SystemStatusHUDChartSample(timestamp: TimeInterval($0), value: Double($0))
        }

        XCTAssertEqual(
            SystemStatusHUDSingleLineChart.downsample(samples, limit: 3),
            [samples[0], samples[5], samples[9]]
        )
    }

    func testDetailChartDownsamplesAcrossTheWholeSelectedRange() {
        let history = (0...100).map { index in
            SystemStatusHistoryPoint(
                timestamp: TimeInterval(index * 60),
                cpuUsage: Double(index) / 100
            )
        }

        let chartData = SystemStatusMetricDetailChartData(
            history: history,
            kind: .cpu,
            range: .twentyFourHours,
            sampleLimit: 3
        )

        XCTAssertEqual(chartData.singleSamples.count, 3)
        XCTAssertEqual(chartData.singleSamples.first?.timestamp, 0)
        XCTAssertEqual(chartData.singleSamples.last?.timestamp, 6_000)
        XCTAssertEqual(chartData.startTimestamp, 0)
        XCTAssertEqual(chartData.endTimestamp, 6_000)
    }

    func testDetailChartBoundsMaximumStoredHistoryToRenderableSampleLimit() {
        let history = (0..<SystemStatusHistoryStore.maximumSampleCount).map { index in
            SystemStatusHistoryPoint(
                timestamp: TimeInterval(index * 10),
                cpuUsage: Double(index % 100) / 100
            )
        }

        let chartData = SystemStatusMetricDetailChartData(
            history: history,
            kind: .cpu,
            range: .twentyFourHours,
            sampleLimit: 120
        )

        XCTAssertEqual(chartData.singleSamples.count, 120)
        XCTAssertEqual(chartData.singleSamples.first?.timestamp, history.first?.timestamp)
        XCTAssertEqual(chartData.singleSamples.last?.timestamp, history.last?.timestamp)
    }

    func testDetailChartCachePreparesEveryRangeBeforeSelection() {
        let history = (0...180).map { index in
            SystemStatusHistoryPoint(
                timestamp: TimeInterval(index * 60),
                cpuUsage: Double(index) / 180
            )
        }

        let chartCache = SystemStatusMetricDetailChartCache(
            history: history,
            kind: .cpu,
            sampleLimit: 20
        )

        for range in SystemStatusMetricDetailRange.allCases {
            let chartData = chartCache.data(for: range)
            XCTAssertEqual(chartData.range, range)
            XCTAssertFalse(chartData.singleSamples.isEmpty)
            XCTAssertLessThanOrEqual(chartData.singleSamples.count, 20)
            XCTAssertEqual(chartData.endTimestamp, history.last?.timestamp)
        }

        XCTAssertEqual(
            chartCache.data(for: .thirtyMinutes).startTimestamp,
            history[150].timestamp
        )
        XCTAssertEqual(
            chartCache.data(for: .twoHours).startTimestamp,
            history[60].timestamp
        )
        XCTAssertEqual(
            chartCache.data(for: .twentyFourHours).startTimestamp,
            history.first?.timestamp
        )
    }

    func testDetailChartAxisAddsEvenlySpacedIntermediateLabels() {
        let day: TimeInterval = 24 * 60 * 60
        let expected: [TimeInterval] = [0, day / 4, day / 2, day * 3 / 4, day]
        let timestamps = SystemStatusMetricDetailAxis.timestamps(start: 0, end: day)

        XCTAssertEqual(timestamps, expected)
        XCTAssertEqual(
            SystemStatusMetricDetailAxis.timestamps(start: 42, end: 42),
            [42]
        )
        XCTAssertTrue(
            SystemStatusMetricDetailAxis.timestamps(start: nil, end: 42).isEmpty
        )
    }

    func testChartGeometryUsesActualIrregularTimestamps() throws {
        let timestamps: [TimeInterval] = [0, 300, 600, 603, 606]
        let range = try XCTUnwrap(
            SystemStatusHUDChartGeometry.timeRange(timestamps: timestamps)
        )

        XCTAssertEqual(
            SystemStatusHUDChartGeometry.x(for: 600, in: range, width: 100),
            99.01,
            accuracy: 0.01
        )
        let middleIndex = try XCTUnwrap(
            SystemStatusHUDChartGeometry.nearestIndex(to: 0.5, timestamps: timestamps)
        )
        XCTAssertEqual(timestamps[middleIndex], 300)
        XCTAssertEqual(
            try XCTUnwrap(SystemStatusHUDChartGeometry.fraction(at: 2, timestamps: timestamps)),
            600 / 606,
            accuracy: 0.0001
        )
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

    func testGPUUtilizationDoesNotUsePipelineCountersAsTotalUsage() {
        XCTAssertNil(SystemStatusSampler.gpuUtilization(from: [
            "Renderer Utilization %": 100,
            "Tiler Utilization %": 100
        ]))
    }

    func testBatteryHealthPercentPrefersNominalChargeCapacity() {
        let health = SystemStatusSampler.batteryHealthPercent(
            designCapacity: 10_000,
            nominalChargeCapacity: 8_300,
            appleRawMaxCapacity: 7_800
        )

        XCTAssertEqual(health, 83)
    }

    func testSystemPowerBatteryHealthPercentUsesSystemProfilerMaximumCapacity() {
        let output = """
        {
          "SPPowerDataType" : [
            {
              "sppower_battery_health_info" : {
                "sppower_battery_cycle_count" : 253,
                "sppower_battery_health" : "Good",
                "sppower_battery_health_maximum_capacity" : "84%"
              }
            }
          ]
        }
        """

        XCTAssertEqual(
            SystemStatusSampler.systemPowerBatteryHealthPercent(fromSystemProfilerJSON: output),
            84
        )
    }

    func testBatteryHealthPercentFallsBackToAppleRawMaxCapacity() {
        let health = SystemStatusSampler.batteryHealthPercent(
            designCapacity: 10_000,
            nominalChargeCapacity: nil,
            appleRawMaxCapacity: 7_800
        )

        XCTAssertEqual(health, 78)
    }

    func testBatteryHealthPercentRoundsAndClampsLikeMoleStatus() {
        XCTAssertEqual(
            SystemStatusSampler.batteryHealthPercent(
                designCapacity: 10_000,
                nominalChargeCapacity: 8_249,
                appleRawMaxCapacity: nil
            ),
            82
        )
        XCTAssertEqual(
            SystemStatusSampler.batteryHealthPercent(
                designCapacity: 10_000,
                nominalChargeCapacity: 8_250,
                appleRawMaxCapacity: nil
            ),
            83
        )
        XCTAssertEqual(
            SystemStatusSampler.batteryHealthPercent(
                designCapacity: 10_000,
                nominalChargeCapacity: 12_000,
                appleRawMaxCapacity: nil
            ),
            100
        )
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

    func testBatteryPowerNormalizerDerivesWattsFromVoltageAndAmperageLikeMoleStatus() throws {
        let watts = try XCTUnwrap(
            SystemStatusBatteryPowerNormalizer.derivedWatts(
                voltageMillivolts: 12_000,
                amperageMilliamps: -1_500
            )
        )

        XCTAssertEqual(watts, 18.0, accuracy: 0.001)
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

    func testProcessParserKeepsCPUAndMemoryLeadersAsCandidates() {
        let output = """
           1  90.0  1.0   1024 /usr/bin/cpu-leader
           2  80.0  2.0   2048 /usr/bin/cpu-runner-up
           3   1.0 40.0  40960 /usr/bin/memory-leader
           4   2.0 30.0  30720 /usr/bin/memory-runner-up
           5   3.0  3.0   3072 /usr/bin/other
        """

        let candidates = SystemStatusProcessParser.parsePSOutputCandidates(output, limitPerSort: 2)

        XCTAssertEqual(Set(candidates.map(\.pid)), [1, 2, 3, 4])
    }

    func testFormatterOutputsExpectedValues() {
        XCTAssertEqual(SystemStatusFormatter.percent(0.425), "43%")
        XCTAssertEqual(SystemStatusFormatter.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(SystemStatusFormatter.speed(1_048_576), "1.0 MB/s")
        XCTAssertEqual(SystemStatusFormatter.temperature(nil), "—°C")
        XCTAssertEqual(SystemStatusFormatter.power(29.813), "30W")
        XCTAssertEqual(SystemStatusFormatter.uptime(90_000), "1d 1h")
    }
}
