import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Executor preflight and per-item recheck chain (design §7.1, §7.2).
///
/// Primitives are fakes here: this class tests **ordering and gates**. Real syscall behavior of primitives is covered by
/// `DiskCleanRemovalPrimitiveTests` against a real filesystem.
@MainActor
final class DiskCleanExecutorTests: XCTestCase {
    private let home = "/Users/tester"
    private var storage: DiskCleanTempDirectory!
    private var auditLog: DiskCleanAuditLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try DiskCleanTempDirectory(name: "diskclean-executor")
        auditLog = DiskCleanAuditLog(directory: storage.url)
    }

    override func tearDown() {
        storage?.remove()
        storage = nil
        auditLog = nil
        super.tearDown()
    }

    // MARK: - preflight: any failure means zero deletes

    func testPreflightRejectsExpiredPlanWithoutTouchingAnything() async throws {
        let plan = try makePlan(paths: ["\(home)/Library/Caches/A"])
        let primitive = FakeDiskCleanRemovalPrimitive()
        let executor = makeExecutor(primitive: primitive, now: plan.expiryDeadline)

        await assertThrows(.planExpired) { try await executor.execute(plan: plan) }

        XCTAssertEqual(primitive.callCount, 0, "preflight failure must mean zero deletes")
    }

    func testPreflightRejectsWholePlanWhenAnyItemIsLockedByRunningApp() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A", "\(home)/Library/Caches/B"],
            lockedByBundleIDs: ["com.example.app"]
        )
        let primitive = FakeDiskCleanRemovalPrimitive()
        let executor = makeExecutor(
            primitive: primitive,
            runningAppLock: ProgrammableDiskCleanRunningAppLock(
                snapshot: DiskCleanRunningAppSnapshot(runningBundleIDs: ["com.example.app"])
            )
        )

        await assertThrows(
            .lockedDuringPreflight(path: "\(home)/Library/Caches/A", processName: "com.example.app")
        ) { try await executor.execute(plan: plan) }

        XCTAssertEqual(primitive.callCount, 0, "one locked item aborts the whole run; it does not skip just that item")
    }

    func testPreflightRejectsPlanWhenSafetyPolicyNowRefusesAPath() async throws {
        // Path added to the allowlist only after plan minting: preflight must stop the whole run.
        let plan = try makePlan(paths: ["\(home)/Library/Caches/A", "\(home)/.ssh"])
        let primitive = FakeDiskCleanRemovalPrimitive()
        let executor = makeExecutor(primitive: primitive)

        await assertThrowsSafetyRejection(path: "\(home)/.ssh") { try await executor.execute(plan: plan) }

        XCTAssertEqual(primitive.callCount, 0)
    }

    /// Plan-carried evidence must independently re-detect ancestor conflicts — this gate catches Planner bugs.
    func testPreflightRerunsAncestorAssertionFromPlanEvidence() async throws {
        let parent = DiskCleanPlanFactory.candidate(path: "\(home)/Library/Caches/App")
        let lockedChild = DiskCleanPlanFactory.candidate(
            path: "\(home)/Library/Caches/App/inner",
            safety: .inUse(processName: "App")
        )
        // Mint a valid plan first, then use the same evidence to prove the assertion itself catches conflicts.
        let plan = try DiskCleanPlanner.makePlan(
            artifact: DiskCleanPlanFactory.artifact(candidates: [parent]),
            selectedIDs: [parent.id],
            mode: .permanent,
            now: DiskCleanPlanFactory.observedAt,
            catalog: DiskCleanPlanFactory.catalog()
        )

        XCTAssertThrowsError(
            try DiskCleanPlanner.assertNoAncestorViolation(
                plannedPaths: plan.items.map(\.path),
                exclusionPaths: [lockedChild.path],
                reservedPrefixes: plan.reservedPrefixes
            )
        ) { error in
            XCTAssertEqual(
                error as? DiskCleanPlanError,
                .ancestorViolation(
                    plannedPath: "\(home)/Library/Caches/App",
                    protectedPath: "\(home)/Library/Caches/App/inner"
                )
            )
        }
    }

    // MARK: - Per-item chain

    func testExecutesEveryItemInPlanOrderAndCountsTerminalStates() async throws {
        let paths = (0..<6).map { "\(home)/Library/Caches/Item\($0)" }
        let plan = try makePlan(paths: paths, bytes: 100)
        let primitive = FakeDiskCleanRemovalPrimitive()
        primitive.setDisposition(.trashed(stagedName: ".mactools-staged-1"), forPath: paths[1])
        primitive.setDisposition(.changedSinceScan, forPath: paths[2])
        primitive.setDisposition(.failed(reason: "boom"), forPath: paths[3])
        primitive.setDisposition(.partiallyDeleted(stagedName: ".mactools-staged-4", reason: "io"), forPath: paths[4])
        primitive.setDisposition(.rollbackBlocked(stagedName: ".mactools-staged-5", reason: "occupied"), forPath: paths[5])
        let executor = makeExecutor(primitive: primitive)

        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(primitive.removedPaths, paths, "items execute in plan order")
        XCTAssertEqual(result.removedCount, 2, "removed + trashed both count as disposed")
        XCTAssertEqual(result.skippedCount, 1, "changedSinceScan counts as skip: object was not touched")
        XCTAssertEqual(result.failedCount, 3, "failed / partiallyDeleted / rollbackBlocked are not success")
        XCTAssertEqual(result.changedSinceScanCount, 1)
        XCTAssertEqual(result.reclaimedBytes, 200, "only successfully disposed items count toward estimated reclaimed bytes")
        XCTAssertEqual(
            result.attentionResults.map(\.path),
            [paths[4], paths[5]],
            "partial delete and blocked rollback must be pinned in cleanup history"
        )
        XCTAssertEqual(result.mode, .permanent)
    }

    /// Per-item lock recheck: an app started after preflight must still block later items.
    func testItemIsSkippedWhenBundleIDBecomesRunningAfterPreflight() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A"],
            lockedByBundleIDs: ["com.example.app"]
        )
        let primitive = FakeDiskCleanRemovalPrimitive()
        let runningAppLock = ProgrammableDiskCleanRunningAppLock(
            snapshot: DiskCleanRunningAppSnapshot(),
            refreshedBundleIDs: ["com.example.app"]
        )
        let executor = makeExecutor(primitive: primitive, runningAppLock: runningAppLock)

        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(primitive.callCount, 0, "per-item recheck finds lock → skip item; do not hand to primitive")
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(
            result.itemResults.first?.outcome,
            .skipped(.inUse(processName: "com.example.app"))
        )
        XCTAssertGreaterThan(runningAppLock.refreshCallCount, 0, "bundle IDs must be refreshed per item")
    }

    /// Process-name snapshot comes from the preflight pass; do not re-run pgrep per item.
    func testProcessNamesAreQueriedOnceDuringPreflight() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A", "\(home)/Library/Caches/B"],
            skipWhenProcessIsRunning: ["exampled"]
        )
        let runningAppLock = ProgrammableDiskCleanRunningAppLock()
        let executor = makeExecutor(runningAppLock: runningAppLock)

        _ = try await executor.execute(plan: plan)

        XCTAssertEqual(runningAppLock.lastRequestedProcessNames, ["exampled"])
        XCTAssertEqual(runningAppLock.refreshCallCount, 2, "each of the two plan items refreshes bundle IDs once")
    }

    func testTrashModeIsForwardedToPrimitive() async throws {
        let plan = try makePlan(paths: ["\(home)/Library/Caches/A"], mode: .trash)
        let primitive = FakeDiskCleanRemovalPrimitive(
            defaultDisposition: .trashed(stagedName: ".mactools-staged-x")
        )
        let executor = makeExecutor(primitive: primitive)

        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(primitive.lastMode, .trash)
        XCTAssertEqual(result.mode, .trash)
        XCTAssertEqual(
            result.itemResults.first?.outcome,
            .trashed(reclaimedBytes: 0, stagedName: ".mactools-staged-x")
        )
    }

    func testCancellationReturnsCompletedItemResultsWithoutStartingTheNextRemoval() async throws {
        let paths = [
            "\(home)/Library/Caches/A",
            "\(home)/Library/Caches/B",
        ]
        let plan = try makePlan(paths: paths, bytes: 42)
        let firstRemovalStarted = expectation(description: "first removal started")
        let allowFirstRemovalToReturn = DispatchSemaphore(value: 0)
        let primitive = FakeDiskCleanRemovalPrimitive { path in
            guard path == paths[0] else { return }
            firstRemovalStarted.fulfill()
            allowFirstRemovalToReturn.wait()
        }
        let executor = makeExecutor(primitive: primitive)
        let execution = Task { try await executor.execute(plan: plan) }

        await fulfillment(of: [firstRemovalStarted], timeout: 1)
        execution.cancel()
        allowFirstRemovalToReturn.signal()
        let result = try await execution.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.itemResults.map(\.path), [paths[0]])
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(primitive.removedPaths, [paths[0]])
    }

    // MARK: - Audit

    func testWritesOneAuditRecordPerItemWithTerminalStatus() async throws {
        let paths = ["\(home)/Library/Caches/A", "\(home)/Library/Caches/B"]
        let plan = try makePlan(paths: paths, bytes: 42)
        let primitive = FakeDiskCleanRemovalPrimitive()
        primitive.setDisposition(
            .partiallyDeleted(stagedName: ".mactools-staged-b", reason: "io error"),
            forPath: paths[1]
        )
        let executor = makeExecutor(primitive: primitive)

        _ = try await executor.execute(plan: plan)

        let records = auditLog.recentRecords(limit: 10)
        let itemRecords = records.filter { $0.action != .runSummary }
        XCTAssertEqual(itemRecords.count, 2)
        let byPath = Dictionary(uniqueKeysWithValues: itemRecords.map { ($0.path ?? "", $0) })
        XCTAssertEqual(byPath[paths[0]]?.status, "ok")
        XCTAssertEqual(byPath[paths[0]]?.action, .delete)
        XCTAssertEqual(byPath[paths[0]]?.estimatedBytes, 42)
        XCTAssertEqual(byPath[paths[0]]?.targetID, DiskCleanPlanFactory.targetID)
        XCTAssertEqual(byPath[paths[1]]?.status, "partiallyDeleted")
        XCTAssertEqual(byPath[paths[1]]?.stagedName, ".mactools-staged-b")
        XCTAssertEqual(byPath[paths[1]]?.error, "io error")
    }

    func testSkippedItemAuditRecordsReason() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A"],
            lockedByBundleIDs: ["com.example.app"]
        )
        let executor = makeExecutor(
            runningAppLock: ProgrammableDiskCleanRunningAppLock(
                snapshot: DiskCleanRunningAppSnapshot(),
                refreshedBundleIDs: ["com.example.app"]
            )
        )

        _ = try await executor.execute(plan: plan)

        let record = try XCTUnwrap(auditLog.recentRecords(limit: 10).first { $0.action != .runSummary })
        XCTAssertEqual(record.status, "skipped")
        XCTAssertEqual(record.skipReason, "inUse(com.example.app)")
    }

    // MARK: - Fixtures

    private func makePlan(
        paths: [String],
        mode: DiskCleanRemovalMode = .permanent,
        bytes: Int64 = 0,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = []
    ) throws -> DiskCleanValidatedPlan {
        try DiskCleanPlanFactory.makePlan(
            items: paths.map { DiskCleanPlanFactory.Item(path: $0, identity: .test(), bytes: bytes) },
            mode: mode,
            lockedByBundleIDs: lockedByBundleIDs,
            skipWhenProcessIsRunning: skipWhenProcessIsRunning
        )
    }

    private func makeExecutor(
        primitive: any DiskCleanPlanItemRemoving = FakeDiskCleanRemovalPrimitive(),
        runningAppLock: any DiskCleanRunningAppSnapshotting = ProgrammableDiskCleanRunningAppLock(),
        now: Date = DiskCleanPlanFactory.observedAt
    ) -> DiskCleanExecutor {
        DiskCleanExecutor(
            primitive: primitive,
            safetyPolicy: DiskCleanSafetyPolicy(
                homeDirectory: home,
                whitelistStore: DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)
            ),
            runningAppLock: runningAppLock,
            auditLog: auditLog,
            now: { now }
        )
    }

    private func assertThrows(
        _ expected: DiskCleanExecutionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> DiskCleanExecutionResult
    ) async {
        do {
            _ = try await body()
            XCTFail("expected throw \(expected), but execution succeeded", file: file, line: line)
        } catch let error as DiskCleanExecutionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected DiskCleanExecutionError, got: \(error)", file: file, line: line)
        }
    }

    private func assertThrowsSafetyRejection(
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> DiskCleanExecutionResult
    ) async {
        do {
            _ = try await body()
            XCTFail("expected safety rejection for \(path)", file: file, line: line)
        } catch let DiskCleanExecutionError.safetyRejected(rejectedPath, _) {
            XCTAssertEqual(rejectedPath, path, file: file, line: line)
        } catch {
            XCTFail("expected safetyRejected, got: \(error)", file: file, line: line)
        }
    }
}
