import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Plan minting validation matrix (design §6.1).
///
/// Any failed check must `throw` — no plan means no deletes; the cheapest reliable gate on the execution path.
@MainActor
final class DiskCleanPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let targetID = DiskCleanPlanFactory.targetID

    // MARK: - Happy path

    func testMintsPlanWithFrozenModeTotalsAndEvidence() throws {
        let first = candidate(path: "/cache/a", bytes: 100)
        let second = candidate(path: "/cache/b", bytes: 250)
        let excluded = candidate(path: "/cache/locked", safety: .inUse(processName: "App"))

        let plan = try makePlan(
            candidates: [first, second, excluded],
            selectedIDs: [first.id, second.id],
            reservedRootPaths: ["/reserved/root"]
        )

        XCTAssertEqual(plan.items.map(\.path), ["/cache/a", "/cache/b"], "execution order follows artifact order and is reproducible")
        XCTAssertEqual(plan.totalEstimatedBytes, 350)
        XCTAssertEqual(plan.itemCount, 2)
        XCTAssertEqual(plan.mode, .permanent)
        XCTAssertEqual(plan.minObservedAt, DiskCleanPlanFactory.observedAt)
        XCTAssertEqual(
            plan.expiryDeadline,
            DiskCleanPlanFactory.observedAt.addingTimeInterval(DiskCleanScanFreshness.window)
        )
        XCTAssertEqual(plan.exclusionPaths, ["/cache/locked"], "candidates not in the plan all go into the exclusion set")
        XCTAssertEqual(plan.reservedPrefixes, ["/reserved/root"], "reserved prefixes are derived from the artifact so callers cannot omit them")
    }

    // MARK: - Rejection matrix

    func testEmptySelectionIsRejected() {
        let candidate = candidate(path: "/cache/a")

        assertThrows(.emptySelection) {
            try makePlan(candidates: [candidate], selectedIDs: [])
        }
    }

    /// Unauthorized selection: the provided id is not in the artifact.
    func testSelectionOutsideArtifactIsRejected() {
        let candidate = candidate(path: "/cache/a")

        assertThrows(.invalidSelection(candidateID: "ghost")) {
            try makePlan(candidates: [candidate], selectedIDs: [candidate.id, "ghost"])
        }
    }

    /// Unauthorized selection: candidate exists but is not cleanable (locked / protected / allowlisted).
    func testSelectingNonCleanableCandidateIsRejected() {
        let locked = candidate(path: "/cache/locked", safety: .inUse(processName: "App"))

        assertThrows(.invalidSelection(candidateID: locked.id)) {
            try makePlan(candidates: [locked], selectedIDs: [locked.id])
        }
    }

    /// Unauthorized selection: completeness is not complete, even if safety allows it.
    func testSelectingPartialCandidateIsRejected() {
        let partial = DiskCleanPlanFactory.candidate(
            path: "/cache/partial",
            sizeResult: .testPartial(reasons: [.crossedMountPoint], identity: .test())
        )

        assertThrows(.invalidSelection(candidateID: partial.id)) {
            try makePlan(candidates: [partial], selectedIDs: [partial.id])
        }
    }

    /// Size is known but root identity is missing → executor cannot re-verify; reject.
    func testSelectingCandidateWithoutRootIdentityIsRejected() {
        let noIdentity = DiskCleanPlanFactory.candidate(
            path: "/cache/no-identity",
            sizeResult: DiskCleanSizeResult(
                estimatedBytes: 10,
                fileCount: 1,
                completeness: .complete,
                rootIdentity: nil,
                observedAt: DiskCleanPlanFactory.observedAt
            )
        )

        assertThrows(.invalidSelection(candidateID: noIdentity.id)) {
            try makePlan(candidates: [noIdentity], selectedIDs: [noIdentity.id])
        }
    }

    /// Ancestor conflict: planned path covers a candidate not in the plan.
    func testPlannedPathCoveringExcludedCandidateIsRejected() {
        let parent = candidate(path: "/cache/app")
        let lockedChild = candidate(path: "/cache/app/inner", safety: .inUse(processName: "App"))

        assertThrows(.ancestorViolation(plannedPath: "/cache/app", protectedPath: "/cache/app/inner")) {
            try makePlan(candidates: [parent, lockedChild], selectedIDs: [parent.id])
        }
    }

    /// Ancestor conflict: planned path covers a reserved root of a skipped target (that subtree was never scanned).
    func testPlannedPathCoveringReservedPrefixIsRejected() {
        let parent = candidate(path: "/cache/app")

        assertThrows(.ancestorViolation(plannedPath: "/cache/app", protectedPath: "/cache/app/unscanned")) {
            try makePlan(
                candidates: [parent],
                selectedIDs: [parent.id],
                reservedRootPaths: ["/cache/app/unscanned"]
            )
        }
    }

    /// Equal paths also conflict: the same path both planned and reserved means contradictory evidence.
    func testPlannedPathEqualToReservedPrefixIsRejected() {
        let parent = candidate(path: "/cache/app")

        assertThrows(.ancestorViolation(plannedPath: "/cache/app", protectedPath: "/cache/app")) {
            try makePlan(candidates: [parent], selectedIDs: [parent.id], reservedRootPaths: ["/cache/app"])
        }
    }

    /// Shared name prefix is not ancestry: `/cache/app-extra` is not under `/cache/app`.

    func testExpiredResultIsRejected() {
        let candidate = candidate(path: "/cache/a", observedAt: now)

        assertThrows(.resultExpired) {
            try makePlan(
                candidates: [candidate],
                selectedIDs: [candidate.id],
                now: now.addingTimeInterval(DiskCleanScanFreshness.window)
            )
        }
    }

    // MARK: - Fixtures

    private func candidate(
        path: String,
        bytes: Int64 = 10,
        safety: DiskCleanSafetyStatus = .allowed,
        observedAt: Date = DiskCleanPlanFactory.observedAt
    ) -> DiskCleanCandidate {
        DiskCleanPlanFactory.candidate(
            path: path,
            bytes: bytes,
            observedAt: observedAt,
            safety: safety
        )
    }

    private func makePlan(
        candidates: [DiskCleanCandidate],
        selectedIDs: Set<DiskCleanCandidate.ID>,
        reservedRootPaths: [String] = [],
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = [],
        now: Date? = nil
    ) throws -> DiskCleanValidatedPlan {
        try DiskCleanPlanner.makePlan(
            artifact: DiskCleanPlanFactory.artifact(
                candidates: candidates,
                reservedRootPaths: reservedRootPaths
            ),
            selectedIDs: selectedIDs,
            mode: .permanent,
            now: now ?? self.now,
            catalog: DiskCleanPlanFactory.catalog(
                lockedByBundleIDs: lockedByBundleIDs,
                skipWhenProcessIsRunning: skipWhenProcessIsRunning
            )
        )
    }

    private func assertThrows(
        _ expected: DiskCleanPlanError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> DiskCleanValidatedPlan
    ) {
        do {
            _ = try body()
            XCTFail("expected throw \(expected), but plan minting succeeded", file: file, line: line)
        } catch let error as DiskCleanPlanError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected DiskCleanPlanError, got: \(error)", file: file, line: line)
        }
    }
}
