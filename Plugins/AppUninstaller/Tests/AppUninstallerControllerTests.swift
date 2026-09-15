import Foundation
import XCTest
@testable import AppUninstallerPlugin

@MainActor
final class AppUninstallerControllerTests: XCTestCase {
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
