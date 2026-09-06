import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Audit log field completeness and rotation (design §7.8).
final class DiskCleanAuditLogTests: XCTestCase {
    private var storage: DiskCleanTempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try DiskCleanTempDirectory(name: "diskclean-audit")
    }

    override func tearDown() {
        storage?.remove()
        storage = nil
        super.tearDown()
    }

    func testInitDoesNotTouchFileSystem() {
        let untouched = storage.resolve("never-created")

        _ = DiskCleanAuditLog(directory: untouched)

        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testRecordRoundTripsEveryField() throws {
        let log = DiskCleanAuditLog(directory: storage.url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        log.append(
            DiskCleanAuditLog.Record(
                timestamp: timestamp,
                action: .delete,
                targetID: "cache.example",
                legacyRuleID: "cache.legacy",
                category: DiskCleanCategoryID.appCaches.rawValue,
                path: "/cache/app",
                stagedName: ".mactools-staged-abc",
                estimatedBytes: 4_096,
                status: "partiallyDeleted",
                skipReason: nil,
                error: "Failed to delete file (Permission denied)"
            )
        )

        let record = try XCTUnwrap(log.recentRecords(limit: 1).first)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(record.action, .delete)
        XCTAssertEqual(record.targetID, "cache.example")
        XCTAssertEqual(record.legacyRuleID, "cache.legacy")
        XCTAssertEqual(record.category, "appCaches")
        XCTAssertEqual(record.path, "/cache/app")
        XCTAssertEqual(record.stagedName, ".mactools-staged-abc")
        XCTAssertEqual(record.estimatedBytes, 4_096)
        XCTAssertEqual(record.status, "partiallyDeleted")
        XCTAssertNil(record.skipReason)
        XCTAssertEqual(record.error, "Failed to delete file (Permission denied)")
    }

    func testRecentRecordsAreNewestFirstAndRespectLimit() {
        let log = DiskCleanAuditLog(directory: storage.url)
        for index in 0..<5 {
            log.append(record(status: "ok-\(index)", secondsSinceEpoch: Double(1_000 + index * 10)))
        }

        let records = log.recentRecords(limit: 3)

        XCTAssertEqual(records.map(\.status), ["ok-4", "ok-3", "ok-2"])
    }

    /// Rotate to `.1` when the threshold is hit (tests inject a small value); keep 2 generations.
    func testRotatesAtThresholdAndKeepsTwoGenerations() throws {
        let log = DiskCleanAuditLog(directory: storage.url, maximumFileSizeBytes: 400)

        for index in 0..<12 {
            log.append(record(status: "gen-\(index)", secondsSinceEpoch: Double(1_000 + index)))
        }

        let currentExists = FileManager.default.fileExists(
            atPath: storage.resolve(DiskCleanAuditLog.fileName).path
        )
        let rotatedExists = FileManager.default.fileExists(
            atPath: storage.resolve(DiskCleanAuditLog.rotatedFileName).path
        )
        XCTAssertTrue(currentExists)
        XCTAssertTrue(rotatedExists, "must rotate to .1 once the threshold is exceeded")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: storage.path).sorted(),
            [DiskCleanAuditLog.fileName, DiskCleanAuditLog.rotatedFileName].sorted(),
            "keep only 2 generations; must not pile up .2 / .3"
        )
    }

    /// After rotation, "recent records" must still read across both generations,
    /// otherwise cleanup history would go blank at the rotation boundary.
    ///
    /// Keeping 2 generations means older records are **supposed** to be discarded,
    /// so the assertion is "read content spans beyond the current file",
    /// not "the earliest record is still present".
    func testRecentRecordsSpanRotatedGeneration() throws {
        let log = DiskCleanAuditLog(directory: storage.url, maximumFileSizeBytes: 400)
        for index in 0..<12 {
            log.append(record(status: "gen-\(index)", secondsSinceEpoch: Double(1_000 + index)))
        }

        let statuses = log.recentRecords(limit: 50).map(\.status)
        let currentGeneration = try String(
            contentsOf: storage.resolve(DiskCleanAuditLog.fileName),
            encoding: .utf8
        )

        XCTAssertEqual(statuses.first, "gen-11", "newest record comes first")
        XCTAssertTrue(
            statuses.contains { !currentGeneration.contains("\"status\":\"\($0)\"") },
            "the generation rotated to .1 must still be readable, or history would go blank at rotation"
        )
        let indices = statuses.compactMap { Int($0.dropFirst("gen-".count)) }
        XCTAssertEqual(indices, indices.sorted(by: >), "merged generations must remain reverse-chronological")
    }

    private func record(status: String, secondsSinceEpoch: Double) -> DiskCleanAuditLog.Record {
        DiskCleanAuditLog.Record(
            timestamp: Date(timeIntervalSince1970: secondsSinceEpoch),
            action: .trash,
            targetID: "cache.example",
            path: "/cache/app",
            estimatedBytes: 1,
            status: status
        )
    }

    func testRunSummaryRecordRoundTripsEveryField() throws {
        let log = DiskCleanAuditLog(directory: storage.url)
        let timestamp = Date(timeIntervalSince1970: 1_700_100_000)

        log.append(
            DiskCleanAuditLog.Record(
                timestamp: timestamp,
                action: .runSummary,
                runID: "run-12345",
                targetID: "summary",
                path: "run://run-12345",
                estimatedBytes: 104_857_600,
                status: "completed",
                categoriesCleaned: ["appCaches", "logs"],
                itemsRemoved: 42,
                bytesRemoved: 104_857_600,
                errorsEncountered: ["Permission denied for /var/log/system.log"],
                isTrash: false
            )
        )

        let record = try XCTUnwrap(log.recentRecords(limit: 1).first)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(record.action, .runSummary)
        XCTAssertEqual(record.runID, "run-12345")
        XCTAssertEqual(record.categoriesCleaned, ["appCaches", "logs"])
        XCTAssertEqual(record.itemsRemoved, 42)
        XCTAssertEqual(record.bytesRemoved, 104_857_600)
        XCTAssertEqual(record.errorsEncountered, ["Permission denied for /var/log/system.log"])
        XCTAssertEqual(record.isTrash, false)
    }

    func testRecentRunsReadsRunSummaryRecords() {
        let log = DiskCleanAuditLog(directory: storage.url)

        for i in 1...3 {
            log.append(
                DiskCleanAuditLog.Record(
                    timestamp: Date(timeIntervalSince1970: Double(2_000 + i * 100)),
                    action: .runSummary,
                    runID: "run-\(i)",
                    targetID: "summary",
                    path: "run://run-\(i)",
                    estimatedBytes: Int64(i * 1024),
                    status: "completed",
                    categoriesCleaned: ["cat-\(i)"],
                    itemsRemoved: i * 5,
                    bytesRemoved: Int64(i * 1024),
                    errorsEncountered: i == 2 ? ["warn"] : [],
                    isTrash: i % 2 == 0
                )
            )
        }

        let runs = log.recentRuns(limit: 2)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].id, "run-3")
        XCTAssertEqual(runs[0].itemsRemoved, 15)
        XCTAssertEqual(runs[0].bytesRemoved, 3072)
        XCTAssertFalse(runs[0].isTrash)

        XCTAssertEqual(runs[1].id, "run-2")
        XCTAssertEqual(runs[1].itemsRemoved, 10)
        XCTAssertEqual(runs[1].bytesRemoved, 2048)
        XCTAssertTrue(runs[1].isTrash)
        XCTAssertTrue(runs[1].needsAttention)
    }

    func testRecentRunsClustersLegacyRecordsWhenSummaryAbsent() {
        let log = DiskCleanAuditLog(directory: storage.url)
        let baseTime = Date(timeIntervalSince1970: 3_000)

        // Cluster 1 (timestamp 3000-3002)
        log.append(
            DiskCleanAuditLog.Record(
                timestamp: baseTime,
                action: .trash,
                category: "appCaches",
                path: "/cache/item1",
                estimatedBytes: 1024,
                status: "ok"
            )
        )
        log.append(
            DiskCleanAuditLog.Record(
                timestamp: baseTime.addingTimeInterval(2),
                action: .trash,
                category: "systemLogs",
                path: "/cache/item2",
                estimatedBytes: 2048,
                status: "ok"
            )
        )

        // Cluster 2 (timestamp 3100)
        log.append(
            DiskCleanAuditLog.Record(
                timestamp: baseTime.addingTimeInterval(100),
                action: .delete,
                category: "downloads",
                path: "/downloads/old",
                estimatedBytes: 4096,
                status: "partiallyDeleted",
                error: "Locked file"
            )
        )

        let runs = log.recentRuns(limit: 10)
        XCTAssertEqual(runs.count, 2, "Must cluster by time window into 2 runs")

        // Most recent first: cluster 2
        XCTAssertEqual(runs[0].itemsRemoved, 0)
        XCTAssertEqual(runs[0].bytesRemoved, 4096)
        XCTAssertTrue(runs[0].needsAttention)
        XCTAssertFalse(runs[0].isTrash)

        // Earlier cluster 1
        XCTAssertEqual(runs[1].itemsRemoved, 2)
        XCTAssertEqual(runs[1].bytesRemoved, 3072)
        XCTAssertFalse(runs[1].needsAttention)
        XCTAssertTrue(runs[1].isTrash)
    }

}
