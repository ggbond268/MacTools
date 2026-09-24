import XCTest
import Darwin
@testable import SystemStatusPlugin

final class SystemStatusMemoryPressureTests: XCTestCase {
    func testNativeDispatchLevelsRemainDistinctFromUsageAndUnknownValues() {
        XCTAssertEqual(SystemStatusMemoryPressure(rawValue: 1), .normal)
        XCTAssertEqual(SystemStatusMemoryPressure(rawValue: 2), .warning)
        XCTAssertEqual(SystemStatusMemoryPressure(rawValue: 4), .critical)
        for unknown in [0, 3, 8, -1] {
            XCTAssertNil(SystemStatusMemoryPressure(rawValue: unknown))
        }
        var stats = vm_statistics64()
        stats.active_count = 60; stats.inactive_count = 20; stats.speculative_count = 5
        stats.wire_count = 10; stats.compressor_page_count = 15
        stats.purgeable_count = 5; stats.external_page_count = 10
        stats.compressions = 1_000_000
        stats.total_uncompressed_pages_in_compressor = 60
        for pageSize: UInt64 in [4096, 16384] {
            let memory = SystemStatusSampler.memorySnapshot(stats: stats, pageSize: pageSize, totalBytes: 100 * pageSize,
                demand: .memory, pressure: .normal, swap: (10 * pageSize, 20 * pageSize))
            XCTAssertEqual(memory.usage, 0.95)
            XCTAssertEqual(memory.pressurePercent, 25)
            XCTAssertEqual(memory.pressure, .normal)
            XCTAssertEqual(memory.swapUsedBytes, 10 * pageSize)
        }
        let pressureOnly = SystemStatusSampler.memorySnapshot(stats: stats, pageSize: 4096, totalBytes: 409600,
            demand: .memoryPressure, pressure: nil)
        XCTAssertEqual(pressureOnly.pressurePercent, 25)
        XCTAssertNil(pressureOnly.pressure)
        XCTAssertNil(pressureOnly.usedBytes)
        let usageOnly = SystemStatusSampler.memorySnapshot(stats: stats, pageSize: 4096, totalBytes: 409600,
            demand: .memoryUsage, pressure: nil)
        XCTAssertEqual(usageOnly.usage, 0.95)
        XCTAssertNil(usageOnly.pressurePercent)
        let unavailable = SystemStatusSampler.memorySnapshot(stats: stats, pageSize: nil, totalBytes: 409600,
            demand: .memoryPressure, pressure: .warning)
        XCTAssertNil(unavailable.pressurePercent)
        XCTAssertEqual(unavailable.pressure, .warning)
        XCTAssertNil(SystemStatusMemoryPressure.estimatedPercentage(wiredPages: 10, compressorPages: 15, pageSize: 4096, totalBytes: 0))
        XCTAssertEqual(SystemStatusMemoryPressure.estimatedPercentage(wiredPages: .max, compressorPages: .max, pageSize: 16384, totalBytes: 1), 100)
        XCTAssertEqual(SystemStatusMemoryPressure.estimatedPercentage(wiredPages: 0, compressorPages: 0, pageSize: 4096, totalBytes: 409600), 0)
    }

    func testHistoryRetainsPressureAndReadsOlderRecordsWithoutInventingPressure() throws {
        let old = Data(#"{"schemaVersion":1,"samples":[{"timestamp":100,"memoryUsage":0.9,"memoryPressure":4}]}"#.utf8)
        let history = try JSONDecoder().decode(SystemStatusHistoryDocument.self, from: old)
        XCTAssertEqual(history.samples.first?.memoryUsage, 0.9)
        XCTAssertEqual(history.samples.first?.memoryPressure, .critical)
        XCTAssertNil(history.samples.first?.memoryPressurePercent)
        XCTAssertTrue(SystemStatusMemoryPressureHistory.samples(history.samples).allSatisfy { !$0.isAvailable })
        var snapshot = SystemStatusSnapshot.empty
        snapshot.memory.pressure = .warning
        snapshot.memory.pressurePercent = 25
        let point = SystemStatusHistoryPoint(timestamp: 101, snapshot: snapshot)
        let restored = try JSONDecoder().decode(
            SystemStatusHistoryPoint.self, from: JSONEncoder().encode(point)
        )
        XCTAssertEqual(restored.memoryPressure, .warning)
        XCTAssertEqual(restored.memoryPressurePercent, 25)
        for value in [Double.nan, .infinity, -1, 101] {
            XCTAssertNil(SystemStatusHistoryPoint(timestamp: 102, memoryPressurePercent: value).validMemoryPressurePercent)
        }
    }

    func testPressureChartsRetainPeaksAndMissingBucketsWithoutChangingUsageCharts() {
        let history: [SystemStatusHistoryPoint] = [
            .init(timestamp: 100, memoryUsage: 0.9),
            .init(timestamp: 101, memoryUsage: 0.9),
            .init(timestamp: 102, memoryUsage: 0.9, memoryPressure: .critical, memoryPressurePercent: 40),
            .init(timestamp: 103, memoryUsage: 0.9, memoryPressure: .normal, memoryPressurePercent: 30),
            .init(timestamp: 104, memoryUsage: 0.9, memoryPressure: .normal, memoryPressurePercent: 80),
            .init(timestamp: 105, memoryUsage: 0.9, memoryPressure: .normal),
            .init(timestamp: 106, memoryUsage: 0.9, memoryPressure: .normal, memoryPressurePercent: 20)
        ]
        let pressure = SystemStatusMetricDetailChartData(
            history: history, kind: .memory, range: .thirtyMinutes, chartMetric: .pressure, sampleLimit: 2
        )
        XCTAssertFalse(pressure.singleSamples[0].isAvailable)
        XCTAssertTrue(pressure.singleSamples.contains { $0.timestamp == 102 && $0.value == 40 && $0.pressure == .critical })
        XCTAssertTrue(pressure.singleSamples.contains { $0.timestamp == 103 && $0.value == 30 && $0.pressure == .normal })
        XCTAssertTrue(pressure.singleSamples.contains { $0.timestamp == 104 && $0.value == 80 && $0.pressure == .normal })
        XCTAssertTrue(pressure.singleSamples.last?.startsNewSegment == true)
        XCTAssertEqual(pressure.statistics.minimum, 20)
        XCTAssertEqual(pressure.statistics.maximum, 80)
        XCTAssertEqual(pressure.statistics.average, 45)
        let usage = SystemStatusMetricDetailChartData(history: history, kind: .memory, range: .thirtyMinutes)
        XCTAssertTrue(usage.singleSamples.allSatisfy { $0.value == 90 })
        XCTAssertEqual(usage.statistics.minimum, 90)
    }

    func testCompactionKeepsPercentageExtremaAndUnavailableIntervals() {
        let history: [SystemStatusHistoryPoint] = [
            .init(timestamp: 120, memoryPressure: .normal, memoryPressurePercent: 20),
            .init(timestamp: 123, memoryPressure: .normal, memoryPressurePercent: 80),
            .init(timestamp: 126, memoryPressure: .normal, memoryPressurePercent: 10),
            .init(timestamp: 129, memoryPressure: .normal, memoryPressurePercent: 30),
            .init(timestamp: 132, memoryPressure: .normal),
            .init(timestamp: 135, memoryPressure: .normal, memoryPressurePercent: 40),
            .init(timestamp: 138, memoryPressure: .critical, memoryPressurePercent: 40),
            .init(timestamp: 141, memoryPressure: .normal, memoryPressurePercent: 40)
        ]
        let compacted = SystemStatusHistoryProcessing.pruned(history,
            referenceDate: Date(timeIntervalSince1970: 200), highResolutionInterval: 0)
        XCTAssertEqual(compacted.compactMap(\.memoryPressurePercent).max(), 80)
        XCTAssertEqual(compacted.compactMap(\.memoryPressurePercent).min(), 10)
        XCTAssertTrue(compacted.contains { $0.timestamp == 132 && $0.memoryPressurePercent == nil })
        XCTAssertTrue(compacted.contains { $0.timestamp == 138 && $0.memoryPressure == .critical })
        let samples = SystemStatusMemoryPressureHistory.samples(compacted)
        let segments = SystemStatusHUDChartGeometry.segments(samples: samples, width: 210) { CGFloat($0) }
        XCTAssertEqual(segments.count, 2)
    }

    func testOlderAndUnknownChartPreferencesDefaultToUsage() throws {
        let data = try JSONEncoder().encode(SystemStatusConfiguration.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for metric: String? in [nil, "unsupported"] {
            object["memoryChartMetric"] = metric
            let decoded = try JSONDecoder().decode(
                SystemStatusConfiguration.self, from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertEqual(decoded.chartMetric(for: .memory), .usage)
            XCTAssertEqual(decoded.menuBarItems, SystemStatusConfiguration.default.menuBarItems)
        }
    }
}
