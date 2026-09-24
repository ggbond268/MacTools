import XCTest
@testable import SystemStatusPlugin

@MainActor
final class SystemStatusChartMetricTests: XCTestCase {
    func testChartPreferencesPersistAndMigrateLegacyMemoryChoice() throws {
        let store = ChartConfigurationStore()
        let settings = SystemStatusSettingsController(store: store)
        settings.setChartMetric(.memory, metric: .pressure)
        let restored = SystemStatusSettingsController(store: store)
        XCTAssertEqual(restored.configuration.chartMetric(for: .memory), .pressure)
        let backup = try XCTUnwrap(settings.makePortablePreferencesBackup())
        let imported = SystemStatusSettingsController(store: ChartConfigurationStore())
        XCTAssertTrue(imported.restorePortablePreferences(from: backup))
        XCTAssertEqual(imported.configuration, settings.configuration)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SystemStatusConfiguration.default)) as? [String: Any])
        object.removeValue(forKey: "chartMetrics")
        object["memoryChartMetric"] = "pressure"
        let legacy = try JSONDecoder().decode(SystemStatusConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.chartMetric(for: .memory), .pressure)
        object["chartMetrics"] = ["cpu": "power", "gpu": "temperature", "memory": "pressure",
                                  "disk": "usage", "network": "activity", "battery": "power"]
        let migrated = try JSONDecoder().decode(SystemStatusConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.chartMetrics, ["memory": .pressure])
        XCTAssertEqual(migrated.chartMetric(for: .cpu), .usage)
        XCTAssertEqual(migrated.chartMetric(for: .gpu), .usage)
        XCTAssertEqual(migrated.chartMetric(for: .disk), .activity)
        XCTAssertEqual(migrated.chartMetric(for: .network), .activity)
        XCTAssertEqual(migrated.chartMetric(for: .battery), .level)
        object["chartMetrics"] = ["cpu": "load", "gpu": "unsupported", "memory": "swap",
                                  "disk": "free", "network": "upload", "battery": "temperature"]
        let future = try JSONDecoder().decode(SystemStatusConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(future.chartMetric(for: .cpu), .usage)
        XCTAssertEqual(future.chartMetric(for: .gpu), .usage)
        XCTAssertEqual(future.chartMetric(for: .memory), .usage)
        XCTAssertEqual(future.chartMetric(for: .disk), .activity)
        XCTAssertEqual(future.chartMetric(for: .network), .activity)
        XCTAssertEqual(future.chartMetric(for: .battery), .level)
        XCTAssertEqual(future.panelItems, SystemStatusConfiguration.default.panelItems)
        XCTAssertEqual(future.menuBarItems, SystemStatusConfiguration.default.menuBarItems)
    }

    func testDefaultChartsAndMemoryChoicePreserveValuesAndUnavailableHistory() throws {
        let oldRecord = try JSONDecoder().decode(SystemStatusHistoryPoint.self, from: Data(#"{"timestamp":100,"cpuUsage":0.5}"#.utf8))
        let measured = SystemStatusHistoryPoint(timestamp: 101, cpuUsage: 0.75, gpuUsage: 0.25,
            memoryUsage: 0.8, memoryPressure: .normal, memoryPressurePercent: 20,
            diskUsage: 0.7, diskReadBytesPerSecond: 100, diskWriteBytesPerSecond: 200,
            networkDownloadBytesPerSecond: 300, networkUploadBytesPerSecond: 400,
            batteryLevel: 0.6,
            cpuTemperatureCelsius: 42, cpuPowerWatts: 8.5, cpuLoadAverage1Minute: 1.25,
            gpuTemperatureCelsius: 39, memoryUsedBytes: 8_000, memorySwapUsedBytes: 512,
            diskFreeBytes: 3_000, batteryPowerWatts: -12, batteryTemperatureCelsius: 31)
        let roundTrip = try JSONDecoder().decode(SystemStatusHistoryPoint.self, from: JSONEncoder().encode(measured))
        XCTAssertEqual(roundTrip, measured)
        for (kind, metric, expected) in [
            (SystemStatusMetricKind.gpu, SystemStatusChartMetric.usage, 25.0),
            (.memory, .usage, 80), (.memory, .pressure, 20), (.battery, .level, 60)
        ] {
            let data = SystemStatusMetricDetailChartData(history: [oldRecord, measured], kind: kind, range: .thirtyMinutes, chartMetric: metric)
            XCTAssertFalse(try XCTUnwrap(data.singleSamples.first).isAvailable)
            XCTAssertEqual(data.singleSamples.last?.value, expected)
            XCTAssertEqual(data.statistics.average, expected)
        }
        let usage = SystemStatusMetricDetailChartData(history: [oldRecord, measured], kind: .cpu, range: .thirtyMinutes)
        XCTAssertEqual(usage.singleSamples.map(\.value), [50, 75])
        let rates = SystemStatusMetricDetailChartData(history: [oldRecord, measured], kind: .disk, range: .thirtyMinutes)
        XCTAssertEqual(rates.statistics.minimum, 300)
        XCTAssertFalse(try XCTUnwrap(rates.rateSamples.first).isAvailable)
        XCTAssertEqual(rates.rateSamples.last?.firstValue, 100)
        XCTAssertEqual(rates.rateSamples.last?.secondValue, 200)
        let network = SystemStatusMetricDetailChartData(history: [oldRecord, measured], kind: .network, range: .thirtyMinutes)
        XCTAssertEqual(network.rateSamples.last?.firstValue, 300)
        XCTAssertEqual(network.rateSamples.last?.secondValue, 400)
    }

    func testChartPathsAndDownsamplingKeepCollectionGaps() {
        let samples: [SystemStatusHUDChartSample] = [
            .init(timestamp: 0, value: 5), .init(timestamp: 1, value: 7),
            .init(timestamp: 2, value: 0, isAvailable: false),
            .init(timestamp: 50, value: 0, isAvailable: false),
            .init(timestamp: 51, value: 8), .init(timestamp: 52, value: 9)
        ]
        let reduced = SystemStatusHUDSingleLineChart.downsample(samples, limit: 3)
        XCTAssertTrue(reduced.contains { !$0.isAvailable })
        let segments = SystemStatusHUDChartGeometry.segments(samples: samples, width: 520) { CGFloat($0) }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.count), [2, 2])
        XCTAssertEqual(segments.first?.last?.x, 10)
        XCTAssertEqual(segments.last?.first?.x, 510)
    }

    func testRateAveragesUseMeasuredIntervalsWithoutCountingRetainedReadingsOrGaps() throws {
        let busy = ratePoint(timestamp: 3, duration: 3, cpuUsage: 1, bytesPerSecond: 1_000)
        let idle = ratePoint(timestamp: 33, duration: 30, cpuUsage: 0, bytesPerSecond: 0)
        let sparse = [SystemStatusHistoryPoint(timestamp: 0, cpuUsage: 0), busy, idle]
        // Other readers can run while the last CPU/network reading is retained.
        let retained = [10.0, 20].map { SystemStatusHistoryPoint(timestamp: $0,
            cpuUsage: 1, diskReadBytesPerSecond: 1_000, networkDownloadBytesPerSecond: 1_000) }
        for kind in [SystemStatusMetricKind.cpu, .disk, .network] {
            func average(_ points: [SystemStatusHistoryPoint]) throws -> Double {
                try XCTUnwrap(SystemStatusMetricDetailChartData(history: points, kind: kind, range: .thirtyMinutes).statistics.average)
            }
            let scale = kind == .cpu ? 100.0 : 1_000
            XCTAssertEqual(try average(sparse), scale * 3 / 33, accuracy: 0.0001)
            XCTAssertEqual(try average(Array(sparse.prefix(2)) + retained + [idle]), try average(sparse), accuracy: 0.0001)
            var resumed = ratePoint(timestamp: 500, duration: 1, cpuUsage: 1, bytesPerSecond: 1_000)
            resumed.collectionID = UUID()
            XCTAssertEqual(try average(sparse + [.init(timestamp: 34), resumed]), scale * 4 / 34, accuracy: 0.0001)
        }
        let legacy = SystemStatusMetricDetailChartData(history: [.init(timestamp: 0, cpuUsage: 0),
            .init(timestamp: 3, cpuUsage: 1)], kind: .cpu, range: .thirtyMinutes)
        XCTAssertNil(legacy.statistics.average)
        XCTAssertEqual(legacy.statistics.maximum, 100)
        let gauge = SystemStatusMetricDetailChartData(history: [.init(timestamp: 0, memoryUsage: 0),
            .init(timestamp: 3, memoryUsage: 1)], kind: .memory, range: .thirtyMinutes)
        XCTAssertEqual(gauge.statistics.average, 50)
    }

    func testArchivedPressurePeaksAndSessionBoundariesSurviveReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let now = Date(timeIntervalSince1970: 7200)
        let start = 3600.0
        let oldSession = UUID(), newSession = UUID()
        var points: [SystemStatusHistoryPoint] = [
            .init(timestamp: start, cpuUsage: 0.1, memoryPressure: .critical, memoryPressurePercent: 80),
            .init(timestamp: start + 57, cpuUsage: 0.2, memoryPressure: .normal, memoryPressurePercent: 20),
            .init(timestamp: 7190, cpuUsage: 0.6, memoryPressure: .normal, memoryPressurePercent: 30),
            .init(timestamp: 7197, cpuUsage: 0.6, memoryPressure: .normal, memoryPressurePercent: 30)
        ]
        for index in points.indices { points[index].collectionID = index < 2 ? oldSession : newSession }
        let compacted = SystemStatusViewModel.prunedDisplayHistory(points, referenceDate: now)
        XCTAssertEqual(compacted.compactMap(\.memoryPressure).map(\.rawValue).max(), 4)
        let store = SystemStatusHistoryStore(fileURL: file)
        _ = await store.appendBatch(points, referenceDate: now)
        let restored = await SystemStatusHistoryStore(fileURL: file).load(referenceDate: now)
        XCTAssertEqual(restored, compacted)
        let chart = SystemStatusMetricDetailChartData(history: restored, kind: .cpu, range: .twoHours)
        let segments = SystemStatusHUDChartGeometry.segments(samples: chart.singleSamples, width: 600) { CGFloat($0) }
        XCTAssertEqual(segments.count, 2)
        XCTAssertNil(SystemStatusHUDChartGeometry.nearestIndex(to: 0.5,
            timestamps: chart.singleSamples.map(\.timestamp), breaksBefore: chart.singleSamples.map(\.startsNewSegment)))
        XCTAssertNil(chart.statistics.average)
        let pressure = SystemStatusMetricDetailChartData(history: restored, kind: .memory, range: .twoHours, chartMetric: .pressure)
        XCTAssertEqual(pressure.statistics.maximum, 80)
        XCTAssertTrue(pressure.singleSamples.contains(where: \.startsNewSegment))
    }

    func testArchivedRateIntegralsSurviveCompactionAppendAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let date = Date(timeIntervalSince1970: 7_200)
        // Native CPU tick totals need not advance in exact proportion to wall time.
        let busy = ratePoint(timestamp: 3_603, duration: 3, cpuUsage: 1, bytesPerSecond: 1_000, cpuTicks: 40)
        let idle = ratePoint(timestamp: 3_633, duration: 30, cpuUsage: 0, bytesPerSecond: 0, cpuTicks: 300)
        let store = SystemStatusHistoryStore(fileURL: file)
        _ = await store.appendBatch([busy, idle], referenceDate: date)
        // Incrementally compacting the same minute must not duplicate its integral.
        let later = ratePoint(timestamp: 3_650, duration: 17, cpuUsage: 0, bytesPerSecond: 0, cpuTicks: 160)
        _ = await store.append(later, referenceDate: date)
        let restored = await SystemStatusHistoryStore(fileURL: file).load(referenceDate: date)
        for kind in [SystemStatusMetricKind.cpu, .disk, .network] {
            let chart = SystemStatusMetricDetailChartData(history: restored, kind: kind, range: .twoHours)
            let scale = kind == .cpu ? 100.0 : 1_000
            let expected = kind == .cpu ? 100.0 * 40 / 500 : 1_000.0 * 3 / 50
            XCTAssertEqual(try XCTUnwrap(chart.statistics.average), expected, accuracy: 0.0001)
            XCTAssertEqual(chart.statistics.maximum, scale)
            XCTAssertEqual(chart.statistics.minimum, 0)
        }
    }

    private func ratePoint(timestamp: TimeInterval, duration: TimeInterval, cpuUsage: Double,
                           bytesPerSecond: UInt64, cpuTicks: Double? = nil) -> SystemStatusHistoryPoint {
        var point = SystemStatusHistoryPoint(timestamp: timestamp, cpuUsage: cpuUsage,
            diskReadBytesPerSecond: bytesPerSecond, diskWriteBytesPerSecond: 0,
            networkDownloadBytesPerSecond: bytesPerSecond, networkUploadBytesPerSecond: 0)
        let interval = SystemStatusSampleInterval(endTimestamp: timestamp, duration: duration)
        var cpuInterval = interval
        cpuInterval.counterWeight = cpuTicks
        point.rates = .init(cpu: .init(value: cpuUsage * 100, interval: cpuInterval),
            disk: .init(value: Double(bytesPerSecond), interval: interval),
            network: .init(value: Double(bytesPerSecond), interval: interval))
        return point
    }
}

@MainActor
private final class ChartConfigurationStore: SystemStatusConfigurationStoring {
    var configuration = SystemStatusConfiguration.default
    func load() -> SystemStatusConfiguration { configuration }
    func save(_ configuration: SystemStatusConfiguration) -> Bool { self.configuration = configuration; return true }
}
