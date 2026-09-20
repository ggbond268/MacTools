import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Cleanup history classification and pin rules (design §7.5, §13-M4-6).
final class DiskCleanCleanupHistoryTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_000)

    func testStatusParsingCoversEveryStatusWrittenByTheAuditLog() {
        let expected: [String: DiskCleanCleanupHistoryStatus] = [
            "ok": .ok,
            "skipped": .skipped,
            "changedSinceScan": .changedSinceScan,
            "failed": .failed,
            "partiallyDeleted": .partiallyDeleted,
            "rollbackBlocked": .rollbackBlocked,
            "reconciledRolledBack": .reconciledRolledBack,
            "reconciledAbsent": .reconciledAbsent,
            // Missing parent directory and missing staged object share the same conclusion: nothing to restore.
            "reconciledParentMissing": .reconciledAbsent,
            "reconcileFailed": .reconcileFailed
        ]

        for (rawValue, status) in expected {
            XCTAssertEqual(DiskCleanCleanupHistoryStatus(rawValue: rawValue), status, rawValue)
        }
        XCTAssertEqual(DiskCleanCleanupHistoryStatus(rawValue: "brandNew"), .unknown("brandNew"))
    }

    /// Only the three "leftovers remain on disk" states need attention. Ordinary failures and skips leave nothing and should not interrupt the user.
    func testOnlyLeftoverStatesNeedAttention() {
        let needsAttention: [DiskCleanCleanupHistoryStatus] = [
            .partiallyDeleted, .rollbackBlocked, .reconcileFailed
        ]
        let quiet: [DiskCleanCleanupHistoryStatus] = [
            .ok, .skipped, .changedSinceScan, .failed,
            .reconciledRolledBack, .reconciledAbsent, .unknown("x")
        ]

        for status in needsAttention {
            XCTAssertTrue(status.needsAttention, "\(status) must be pinned for attention")
        }
        for status in quiet {
            XCTAssertFalse(status.needsAttention, "\(status) must not be pinned")
        }
    }

    func testAttentionEntriesArePinnedAboveTheRest() {
        let records = [
            record(status: "ok", path: "/cache/a"),
            record(status: "skipped", path: "/cache/b"),
            record(status: "rollbackBlocked", path: "/cache/c", stagedName: ".mactools-staged-c"),
            record(status: "ok", path: "/cache/d"),
            record(status: "partiallyDeleted", path: "/cache/e", stagedName: ".mactools-staged-e")
        ]

        let entries = DiskCleanCleanupHistoryEntry.entries(from: records)

        XCTAssertEqual(
            entries.map(\.path),
            ["/cache/c", "/cache/e", "/cache/a", "/cache/b", "/cache/d"],
            "leftover entries are pinned first; the rest keep reverse chronological order"
        )
        XCTAssertEqual(entries.prefix(2).filter(\.needsAttention).count, 2)
    }

    /// Trash objects land under the staged name; without this field the user cannot recover them (design §7.4).
    func testEntryCarriesStagedNameAndOriginalPath() throws {
        let entries = DiskCleanCleanupHistoryEntry.entries(
            from: [record(status: "trashedPlaceholder", path: "/cache/a", stagedName: ".mactools-staged-a")]
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.path, "/cache/a")
        XCTAssertEqual(entry.stagedName, ".mactools-staged-a")
    }

    func testEntriesHaveStableIdentifiersWithinOneLoad() {
        let entries = DiskCleanCleanupHistoryEntry.entries(
            from: [record(status: "ok", path: "/a"), record(status: "ok", path: "/b")]
        )

        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "ids must be unique within a single load")
    }

    private func record(
        status: String,
        path: String,
        stagedName: String? = nil
    ) -> DiskCleanAuditLog.Record {
        DiskCleanAuditLog.Record(
            timestamp: timestamp,
            action: .trash,
            path: path,
            stagedName: stagedName,
            estimatedBytes: 1_024,
            status: status
        )
    }
}


extension DiskCleanCleanupHistoryTests {
    func testCancelledAndInterruptedRunsNeverAppearSuccessful() {
        for status in ["cancelled", "interrupted", "completedWithErrors", "futureStatus"] {
            for count in [0, 1] {
                let run = DiskCleanRunHistoryEntry(id: "run", timestamp: timestamp, isTrash: false,
                    status: status, categoriesCleaned: [], itemsRemoved: count, bytesRemoved: Int64(count))
                XCTAssertFalse(run.isSuccessful)
                XCTAssertNotEqual(run.symbolName, "checkmark.circle.fill")
            }
        }
        let successful = DiskCleanRunHistoryEntry(id: "ok", timestamp: timestamp, isTrash: false,
            status: "ok", categoriesCleaned: [], itemsRemoved: 1, bytesRemoved: 42)
        XCTAssertTrue(successful.isSuccessful)
        XCTAssertEqual(successful.symbolName, "checkmark.circle.fill")
    }

    func testIrreversibleRecoveryResidueNeedsAttention() {
        let status = DiskCleanCleanupHistoryStatus(rawValue: "irreversibleStagedRetained")
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(status, .partiallyDeleted)
    }
}
