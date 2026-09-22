import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Staging journal and crash-point matrix (design §7.6).
final class DiskCleanStagingJournalTests: XCTestCase {
    private var storage: DiskCleanTempDirectory!
    private var journal: DiskCleanStagingJournal!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try DiskCleanTempDirectory(name: "diskclean-journal")
        journal = DiskCleanStagingJournal(directory: storage.url)
    }

    override func tearDown() {
        storage?.remove()
        storage = nil
        journal = nil
        super.tearDown()
    }

    /// Crash point 1: begin is durable, rename not yet done or done without a completion record → entry incomplete.

    /// Crash point 2: completion record is durable → entry is cleared; reconciliation will not touch it.

    func testIrreversiblePhaseSurvivesCompaction() throws {
        let entry = makeEntry(id: "deleting")
        try journal.begin(entry)
        try journal.markIrreversible(entryID: entry.id)
        journal.releaseActive(entryID: entry.id)

        try journal.compact()

        let reopened = DiskCleanStagingJournal(directory: storage.url)
        XCTAssertEqual(
            reopened.pendingEntriesForReconciliation(),
            [.init(entry: entry, phase: .irreversible)]
        )
    }

    /// Live cleanup transactions must not be offered to reconciliation between begin and complete/release.
    func testActiveEntriesAreHiddenFromReconciliationUntilCompleteOrRelease() throws {
        let entry = makeEntry(id: "live")
        try journal.begin(entry)

        XCTAssertEqual(journal.incompleteEntries(), [entry])
        XCTAssertTrue(
            journal.incompleteEntriesForReconciliation().isEmpty,
            "live begin must not be reconciled or compacted away"
        )

        try journal.compact()
        XCTAssertEqual(journal.incompleteEntries(), [entry], "compact must keep active begins")

        // rollbackBlocked path: transaction ended but entry stays incomplete for recovery.
        journal.releaseActive(entryID: entry.id)
        XCTAssertEqual(journal.incompleteEntriesForReconciliation(), [entry])

        journal.complete(entryID: entry.id, status: "removed")
        XCTAssertTrue(journal.incompleteEntries().isEmpty)
        XCTAssertTrue(journal.incompleteEntriesForReconciliation().isEmpty)
    }

    /// A reopened journal (new process) has no active marks and can reconcile unfinished entries.
    func testReopenedJournalSeesIncompleteEntriesForReconciliation() throws {
        let entry = makeEntry(id: "crash")
        try journal.begin(entry)

        let reopened = DiskCleanStagingJournal(directory: storage.url)
        XCTAssertEqual(reopened.incompleteEntriesForReconciliation(), [entry])
    }

    /// On crash the last line may be half-written. Half lines must be skipped without affecting other entries.
    func testTruncatedTrailingLineIsTolerated() throws {
        let entry = makeEntry(id: "one")
        try journal.begin(entry)
        let fileURL = storage.resolve(DiskCleanStagingJournal.fileName)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"begin","entry":{"id":"tr"#.utf8))
        try handle.close()

        XCTAssertEqual(
            journal.incompleteEntries(),
            [entry],
            "a half line may only discard itself. Write-order invariant: incomplete begin = rename not yet done = no orphans"
        )
    }

    func testCorruptedMiddleLineIsSkipped() throws {
        let first = makeEntry(id: "first", timestamp: Date(timeIntervalSince1970: 100))
        let second = makeEntry(id: "second", timestamp: Date(timeIntervalSince1970: 200))
        try journal.begin(first)
        let fileURL = storage.resolve(DiskCleanStagingJournal.fileName)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n".utf8))
        try handle.close()
        try journal.begin(second)

        XCTAssertEqual(journal.incompleteEntries().map(\.id), ["first", "second"])
    }

    func testCompactKeepsOnlyIncompleteEntries() throws {
        let done = makeEntry(id: "done")
        let pending = makeEntry(id: "pending")
        try journal.begin(done)
        try journal.begin(pending)
        journal.complete(entryID: done.id, status: "removed")

        try journal.compact()

        XCTAssertEqual(journal.incompleteEntries(), [pending])
        let contents = try String(contentsOf: storage.resolve(DiskCleanStagingJournal.fileName), encoding: .utf8)
        XCTAssertFalse(contents.contains("done"), "completed entries must not keep space after compaction")
        XCTAssertEqual(contents.split(separator: "\n").count, 1)
    }

    func testBeginPropagatesDirectoryDurabilityFailure() throws {
        struct ExpectedFailure: Error {}
        let failing = DiskCleanStagingJournal(
            directory: storage.resolve("durability-failure"),
            directorySynchronizer: { _ in throw ExpectedFailure() }
        )

        XCTAssertThrowsError(try failing.begin(makeEntry(id: "one"))) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }
    }

    private func makeEntry(
        id: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_000)
    ) -> DiskCleanStagingJournal.Entry {
        DiskCleanStagingJournal.Entry(
            id: id,
            timestamp: timestamp,
            parentPath: "/cache",
            originalName: "app",
            stagedName: ".mactools-staged-\(id)",
            mode: DiskCleanRemovalMode.permanent.rawValue
        )
    }
}
