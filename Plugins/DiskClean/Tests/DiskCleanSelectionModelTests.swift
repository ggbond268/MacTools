import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Selection-model semantic matrix (design §8.1).
///
/// Verifies the combination of "user action × candidate facts" with no UI:
/// detail view and menu bar are just two renderings of these conclusions.
final class DiskCleanSelectionModelTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 10_000)

    // MARK: - Selectability

    func testTogglingUnselectableCandidateIsRejectedAndLeavesNoTrace() {
        var model = DiskCleanSelectionModel()
        let locked = makeCandidate(id: "locked", safety: .inUse(processName: "Safari"))

        XCTAssertFalse(model.setCandidate(locked, isSelected: true), "toggle must be rejected, not merely UI-disabled")
        XCTAssertFalse(model.isSelected(locked))

        // Rejection leaves no record: if the item later becomes selectable, default policy applies rather than a rejected click.
        let unlocked = makeCandidate(id: "locked", risk: .medium)
        XCTAssertFalse(model.isSelected(unlocked))
    }

    // MARK: - Default policy

    func testDefaultSelectionTakesLowRiskOnly() {
        let model = DiskCleanSelectionModel()

        XCTAssertTrue(model.isSelected(makeCandidate(id: "low", risk: .low)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "medium", risk: .medium)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "high", risk: .high)))
    }

    /// Dynamic-rule product targets always have risk >= medium (design §5.5), so default policy excludes them
    /// without the selection model re-detecting "is this a dynamic rule".
    func testDynamicRuleProductsAreNotSelectedByDefault() {
        let model = DiskCleanSelectionModel()
        let dynamicTargets = DiskCleanRuleCatalogV2.current.targets.filter(\.isDynamic)

        XCTAssertFalse(dynamicTargets.isEmpty, "catalog should have dynamic targets or this assertion is vacuous")
        for target in dynamicTargets {
            XCTAssertGreaterThanOrEqual(target.risk, .medium)
            let candidate = makeCandidate(id: target.id, category: target.category, risk: target.risk)
            XCTAssertFalse(model.isSelected(candidate), "\(target.id) must not be default-selected")
        }
    }

    // MARK: - Per-item overrides

    func testExplicitCandidateSelectionOverridesDefaultInBothDirections() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        let medium = makeCandidate(id: "medium", risk: .medium)

        XCTAssertTrue(model.setCandidate(low, isSelected: false))
        XCTAssertTrue(model.setCandidate(medium, isSelected: true))

        XCTAssertFalse(model.isSelected(low))
        XCTAssertTrue(model.isSelected(medium), "user may explicitly select medium; default simply does not")
    }

    // MARK: - Category three-state

    // MARK: - Streaming arrivals × explicit override matrix

    /// Reverse: a default-selected candidate re-sized as partial must leave the selection immediately.
    func testCandidateLeavesSelectionWhenItBecomesIncomplete() {
        let model = DiskCleanSelectionModel()
        let sized = makeCandidate(id: "a")

        XCTAssertTrue(model.isSelected(sized))
        XCTAssertFalse(
            model.isSelected(sized.applying(.testPartial(reasons: [.timedOut], observedAt: observedAt)))
        )
    }

    // MARK: - Derived values and reset

    // MARK: - Fixtures

    private func makeCandidate(
        id: String,
        category: DiskCleanCategoryID = .appCaches,
        risk: DiskCleanRisk = .low,
        bytes: Int64 = 1_024,
        safety: DiskCleanSafetyStatus = .allowed,
        completeness: DiskCleanScanCompleteness = .complete,
        sized: Bool = true
    ) -> DiskCleanCandidate {
        let sizeResult: DiskCleanSizeResult? = sized
            ? DiskCleanSizeResult(
                estimatedBytes: bytes,
                fileCount: 1,
                completeness: completeness,
                rootIdentity: completeness.isComplete ? .test() : nil,
                observedAt: observedAt
            )
            : nil
        return DiskCleanCandidate(
            id: id,
            targetID: "test.target",
            legacyRuleID: "test.target",
            category: category,
            path: "/cache/\(id)",
            risk: risk,
            safety: safety,
            sizeResult: sizeResult
        )
    }
}
