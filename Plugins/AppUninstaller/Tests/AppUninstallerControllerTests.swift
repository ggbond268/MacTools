import Darwin
import Foundation
import XCTest
@testable import AppUninstallerPlugin

@MainActor
final class AppUninstallerControllerTests: XCTestCase {
    func testInstalledInventoryRemainsAvailableDuringAppReview() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let scan = try fixture.scan()
        let controller = makeController(service: FixedUninstallReview(scan: scan))
        controller.browse()
        try await eventually { controller.inventory?.apps.count == 1 }
        controller.review(fixture.app, includeInBatch: false)
        try await eventually { controller.scan?.id == scan.id }
        XCTAssertEqual(controller.inventory?.apps.first?.path, fixture.app.path)
        XCTAssertTrue(controller.selectedApplicationPaths.isEmpty)
        XCTAssertFalse(controller.selectedIDs.contains(fixture.app.path))
        controller.setApplicationSelected(fixture.app.path, selected: true)
        XCTAssertTrue(controller.selectedIDs.contains(fixture.app.path))
    }

    func testManuallyAddedAppCanBeRemovedEvenWhenAbsentFromInventory() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let scan = try fixture.scan()
        let controller = makeController(service: FixedUninstallReview(scan: scan))
        let outside = fixture.root.appendingPathComponent("Outside/Unlisted.app")
        controller.addApplications([fixture.app, outside])
        XCTAssertTrue(controller.selectedApplicationPaths.contains(outside.path))
        controller.setApplicationSelected(outside.path, selected: false)
        XCTAssertFalse(controller.selectedApplicationPaths.contains(outside.path))
        controller.clearSelectedApplications()
        XCTAssertTrue(controller.selectedApplicationPaths.isEmpty)
    }

    func testBatchReviewRequiresFreshConfirmationAndPreservesOptOut() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let cache = try fixture.makeData("Caches")
        let scan = try fixture.scan()
        let history = fixture.history()
        let executor = UninstallExecutor(scanner: fixture.scanner, environment: fixture.environment,
                                         history: history, trash: NeverControllerTrash())
        let controller = AppUninstallerController(service: FixedUninstallReview(scan: scan), executor: executor,
                                                  history: history, processProvider: { .init(paths: [], complete: true) })
        controller.browse()
        try await eventually { controller.inventory?.apps.count == 1 }
        controller.setApplicationSelected(fixture.app.path, selected: true)
        controller.reviewSelectedApplications()
        try await eventually { !controller.isPreparingBatch && controller.batchScans.count == 1 }
        controller.setBatchCandidateSelected(appPath: fixture.app.path, itemID: cache.path, selected: false)
        controller.prepareBatchPlan()
        let plan = try XCTUnwrap(controller.pendingBatchPlan)
        XCTAssertEqual(plan.applicationCount, 1)
        XCTAssertEqual(plan.plans[0].items.map(\.path), [fixture.app.path])
        XCTAssertEqual(plan.plans[0].retained.map(\.path), [cache.path])
        controller.pendingBatchPlan = nil
        controller.removeReviewedBatch(plan)
        XCTAssertFalse(controller.isRemoving)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testBatchStopsAfterPartialAppAndRetainsLaterApplication() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let second = fixture.root.appendingPathComponent("Applications/Second.app")
        try UninstallFixture.makeApp(second, identifier: "org.test.second")
        let scans = [try fixture.scan(), try fixture.scanner.scan(path: second.path, environment: fixture.environment.snapshot)]
        let history = fixture.history()
        let executor = UninstallExecutor(scanner: fixture.scanner, environment: fixture.environment,
                                         history: history,
                                         trash: BlockSecondUninstallTrash(directory: fixture.root.appendingPathComponent("Trash"), blockedPath: second.path))
        let controller = AppUninstallerController(service: MultipleUninstallReviews(scans: scans), executor: executor,
                                                  history: history, processProvider: { .init(paths: [], complete: true) })
        controller.browse()
        try await eventually { controller.inventory?.apps.count == 2 }
        controller.setApplicationSelected(fixture.app.path, selected: true)
        controller.setApplicationSelected(second.path, selected: true)
        controller.reviewSelectedApplications()
        try await eventually { !controller.isPreparingBatch && controller.batchScans.count == 2 }
        controller.prepareBatchPlan()
        let plan = try XCTUnwrap(controller.pendingBatchPlan)
        try await eventually { !controller.batchProcessCheckIncomplete }
        controller.removeReviewedBatch(plan)
        try await eventually { !controller.isRemoving && controller.batchResult != nil }
        XCTAssertEqual(controller.batchResult?.completed, 1)
        XCTAssertEqual(controller.batchResult?.total, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let runs = try await history.load()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.filter(\.complete).count, 1)
    }

    func testOlderReviewCannotReplaceNewApplicationSelection() async throws {
        let first = try UninstallFixture(); defer { first.remove() }
        let second = try UninstallFixture(); defer { second.remove() }
        let firstScan = try first.scan()
        let secondScan = try second.scan()
        let service = DeferredUninstallReview()
        let controller = makeController(service: service)

        controller.review(first.app)
        try await eventually { await service.pendingCount(first.app.path) == 1 }
        controller.review(second.app)
        try await eventually { await service.pendingCount(second.app.path) == 1 }
        await service.complete(firstScan)
        await service.complete(secondScan)
        try await eventually { controller.scan?.id == secondScan.id }

        XCTAssertEqual(controller.selectedPath, second.app.path)
        XCTAssertFalse(controller.isScanning)
        XCTAssertNil(controller.error)
    }

    func testCancelledReviewCannotRepopulateAfterReopening() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let firstScan = try fixture.scan()
        let reopenedScan = try fixture.scan()
        let service = DeferredUninstallReview()
        let controller = makeController(service: service)

        controller.review(fixture.app)
        try await eventually { await service.pendingCount(fixture.app.path) == 1 }
        controller.cancel()
        XCTAssertFalse(controller.isScanning)
        XCTAssertNil(controller.scan)
        XCTAssertNotNil(controller.error)

        controller.review(fixture.app)
        try await eventually { await service.pendingCount(fixture.app.path) == 2 }
        await service.complete(firstScan)
        await service.complete(reopenedScan)
        try await eventually { controller.scan?.id == reopenedScan.id }

        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.isScanning)
    }

    func testChangingSelectionInvalidatesPresentedRemovalPlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let cache = try fixture.makeData("Caches")
        let support = try fixture.makeData("Application Support")
        let scan = try fixture.scan()
        let history = fixture.history()
        let executor = UninstallExecutor(scanner: fixture.scanner, environment: fixture.environment,
                                         history: history, trash: NeverControllerTrash())
        let controller = AppUninstallerController(service: FixedUninstallReview(scan: scan), executor: executor,
                                                  history: history, processProvider: { .init(paths: [], complete: true) })
        controller.review(fixture.app)
        try await eventually { controller.scan?.id == scan.id }
        XCTAssertTrue(controller.selectedIDs.contains(cache.path))
        XCTAssertFalse(controller.selectedIDs.contains(support.path))

        controller.preparePlan()
        let original = try XCTUnwrap(controller.pendingPlan)
        controller.setSelected(cache.path, selected: false)
        controller.setSelected(support.path, selected: true)
        XCTAssertNil(controller.pendingPlan)

        controller.removeReviewedPlan(original)
        XCTAssertFalse(controller.isRemoving)
        XCTAssertNotNil(controller.scan)
        controller.preparePlan()
        let revised = try XCTUnwrap(controller.pendingPlan)
        XCTAssertNotEqual(original.id, revised.id)
        XCTAssertEqual(Set(revised.items.map(\.id)), [fixture.app.path, support.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
        controller.pendingPlan = nil
    }

    func testDismissedConfirmationCannotExecuteItsOldPlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let scan = try fixture.scan()
        let executor = UninstallExecutor(scanner: fixture.scanner, environment: fixture.environment,
                                         history: fixture.history(), trash: NeverControllerTrash())
        let controller = AppUninstallerController(service: FixedUninstallReview(scan: scan), executor: executor,
                                                  processProvider: { .init(paths: [], complete: true) })
        controller.review(fixture.app)
        try await eventually { controller.scan?.id == scan.id }
        controller.preparePlan()
        let plan = try XCTUnwrap(controller.pendingPlan)

        controller.pendingPlan = nil
        controller.removeReviewedPlan(plan)

        XCTAssertFalse(controller.isRemoving)
        XCTAssertEqual(controller.scan?.id, scan.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testProcessRecheckDistinguishesHelpersAndUnavailableCoverage() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let scan = try fixture.scan()
        let process = ControllerProcessState(.init(paths: [fixture.app.path + "/Contents/Helpers/worker"], complete: true))
        let controller = AppUninstallerController(service: FixedUninstallReview(scan: scan), processProvider: { process.get() })
        controller.review(fixture.app)
        try await eventually { controller.hasRunningHelpers }
        XCTAssertFalse(controller.isMainAppRunning)
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(controller.processCheckIncomplete)

        process.set(.init(paths: [], complete: true))
        controller.refreshRunningState()
        try await eventually { !controller.hasRunningHelpers }
        XCTAssertFalse(controller.isRunning)

        process.set(.init(paths: [], complete: false))
        controller.refreshRunningState()
        try await eventually { controller.processCheckIncomplete }
        process.set(.init(paths: [], complete: true))
        controller.refreshRunningState()
        try await eventually { !controller.processCheckIncomplete }
        XCTAssertFalse(controller.isRunning)
    }

    private func makeController(service: any UninstallReviewProviding) -> AppUninstallerController {
        AppUninstallerController(service: service, processProvider: { .init(paths: [], complete: true) })
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected asynchronous controller state was not published", file: file, line: line)
    }
}

private actor DeferredUninstallReview: UninstallReviewProviding {
    private var continuations: [String: [CheckedContinuation<UninstallScan, any Error>]] = [:]

    func review(_ path: String) async throws -> UninstallScan {
        try await withCheckedThrowingContinuation { continuations[path, default: []].append($0) }
    }
    func installedApplications() async throws -> UninstallInventory { .init(apps: [], coverage: []) }
    func pendingCount(_ path: String) -> Int { continuations[path]?.count ?? 0 }
    func complete(_ scan: UninstallScan) {
        guard var queue = continuations[scan.application.path], !queue.isEmpty else { return }
        let continuation = queue.removeFirst()
        continuations[scan.application.path] = queue
        continuation.resume(returning: scan)
    }
}

private struct FixedUninstallReview: UninstallReviewProviding {
    let scan: UninstallScan
    func review(_ path: String) async throws -> UninstallScan { scan }
    func installedApplications() async throws -> UninstallInventory { .init(apps: [scan.application], coverage: []) }
}

private struct MultipleUninstallReviews: UninstallReviewProviding {
    let scans: [UninstallScan]
    func review(_ path: String) async throws -> UninstallScan {
        guard let scan = scans.first(where: { $0.application.path == path }) else { throw AppUninstallerError.invalidApplication }
        return scan
    }
    func installedApplications() async throws -> UninstallInventory {
        .init(apps: scans.map(\.application), coverage: [])
    }
}

private struct BlockSecondUninstallTrash: UninstallTrashing {
    let directory: URL
    let blockedPath: String
    func trash(_ url: URL) throws -> URL? {
        if url.lastPathComponent == URL(fileURLWithPath: blockedPath).lastPathComponent {
            throw AppUninstallerError.io(EACCES)
        }
        return try FixtureTrash(directory: directory).trash(url)
    }
}

private final class ControllerProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UninstallProcessSnapshot
    init(_ value: UninstallProcessSnapshot) { self.value = value }
    func get() -> UninstallProcessSnapshot { lock.withLock { value } }
    func set(_ value: UninstallProcessSnapshot) { lock.withLock { self.value = value } }
}

private struct NeverControllerTrash: UninstallTrashing {
    func trash(_ url: URL) throws -> URL? {
        XCTFail("Controller confirmation tests must never execute removal")
        throw AppUninstallerError.blocked
    }
}
