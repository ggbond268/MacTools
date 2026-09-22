import MacToolsPluginKit
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsControllerTests: XCTestCase {
    func testRefreshMergesMembershipAndReportsPartialFailure() async throws {
        let firstFolder = AppleShortcutFolder(id: UUID(), name: "First")
        let failedFolder = AppleShortcutFolder(id: UUID(), name: "Failed")
        let item = AppleShortcutItem(id: UUID(), name: "Morning")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [firstFolder, failedFolder],
            memberships: [
                firstFolder.id: .success([item]),
                failedFolder.id: .failure(.failed),
            ]
        )
        let controller = makeController(runner: runner)

        await controller.performRefresh()

        XCTAssertEqual(controller.snapshot.discovery.shortcuts.first?.folderIDs, [firstFolder.id])
        XCTAssertEqual(controller.snapshot.discovery.failedFolderIDs, [failedFolder.id])
        XCTAssertNotNil(controller.snapshot.errorMessage)
        XCTAssertNotNil(controller.snapshot.lastSuccessfulRefresh)
    }

    func testFailedFolderMembershipPreservesPreviousMembers() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Folder")
        let item = AppleShortcutItem(id: UUID(), name: "Keep", folderIDs: [folder.id])
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [folder],
            memberships: [folder.id: .success([item])]
        )
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        await runner.setMemberships([folder.id: .failure(.failed)])

        await controller.performRefresh()

        XCTAssertEqual(controller.snapshot.discovery.folderMemberships[folder.id], [item.id])
        XCTAssertEqual(controller.snapshot.discovery.shortcuts.first?.folderIDs, [folder.id])
    }

    func testCancellingRefreshDoesNotStartQueuedMembershipQueries() async throws {
        let folders = (0 ..< 12).map {
            AppleShortcutFolder(id: UUID(), name: "Folder \($0)")
        }
        let runner = AppleShortcutsRunnerStub(
            folders: folders,
            membershipDelay: .seconds(5)
        )
        let controller = makeController(runner: runner)
        controller.setSettingsVisible(true)
        for _ in 0 ..< 200 {
            let callCount = (await runner.observedMembershipCallIDs()).count
            if callCount == AppleShortcutsController.maximumConcurrentMembershipQueries { break }
            await Task.yield()
        }

        controller.deactivate()
        try await Task.sleep(for: .milliseconds(100))

        let callIDs = await runner.observedMembershipCallIDs()
        XCTAssertEqual(
            callIDs.count,
            AppleShortcutsController.maximumConcurrentMembershipQueries
        )
    }

    func testTotalRefreshFailurePreservesLastSuccessfulSnapshot() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Preserved")
        let runner = AppleShortcutsRunnerStub(shortcuts: [item])
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        await runner.setListFails(true)

        await controller.performRefresh()

        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [item])
        XCTAssertNotNil(controller.snapshot.errorMessage)
    }

    func testRunLimitAndDuplicatePrevention() async throws {
        let runner = AppleShortcutsRunnerStub(delay: .seconds(5))
        let controller = makeController(runner: runner)
        let ids = (0 ..< 5).map { _ in UUID() }
        let runs = try ids.prefix(4).map {
            try controller.startExecution(shortcutID: $0, name: "Run").get()
        }

        XCTAssertEqual(runs.count, 4)
        XCTAssertThrowsError(
            try controller.startExecution(shortcutID: ids[0], name: "Duplicate").get()
        ) { error in
            XCTAssertEqual(error as? AppleShortcutsExecutionStartError, .alreadyRunning)
        }
        let fifthResult = controller.startExecution(shortcutID: ids[4], name: "Fifth")
        XCTAssertThrowsError(try fifthResult.get()) { error in
            guard let startError = error as? AppleShortcutsExecutionStartError else {
                return XCTFail("Expected a typed execution admission error")
            }
            XCTAssertEqual(startError, .concurrencyLimit)
            controller.presentExecutionStartError(startError)
        }
        XCTAssertEqual(controller.snapshot.errorMessage, "同时最多运行 4 个快捷指令。")

        controller.deactivate()
        for (index, run) in runs.enumerated() {
            let result = await controller.waitForExecution(run, shortcutID: ids[index])
            XCTAssertEqual(result, .cancelled)
        }
    }

    func testDeactivationClearsExecutionAndRejectsLateRunCompletion() async throws {
        let shortcutID = UUID()
        let runner = AppleShortcutsRunnerStub(
            delay: .milliseconds(100),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        let run = try controller.startExecution(shortcutID: shortcutID, name: "Late").get()
        for _ in 0 ..< 100 {
            if !(await runner.observedRunIDs()).isEmpty { break }
            await Task.yield()
        }
        XCTAssertNotNil(controller.executionStore.record(for: shortcutID))

        controller.deactivate()
        controller.activate()
        let result = await controller.waitForExecution(run, shortcutID: shortcutID)

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(controller.executionStore.record(for: shortcutID))
        XCTAssertNil(controller.snapshot.errorMessage)
        XCTAssertNil(controller.snapshot.operationMessage)
    }

    func testOpenUsesUniqueCurrentNameAndRejectsDuplicateNames() async throws {
        let first = AppleShortcutItem(id: UUID(), name: "Duplicate")
        let second = AppleShortcutItem(id: UUID(), name: "duplicate")
        let runner = AppleShortcutsRunnerStub(shortcuts: [first, second])
        let controller = makeController(runner: runner)
        await controller.performRefresh()

        controller.openInShortcuts(first.id)
        for _ in 0 ..< 20 { await Task.yield() }
        var viewNames = await runner.observedViewNames()
        XCTAssertTrue(viewNames.isEmpty)
        XCTAssertNotNil(controller.snapshot.errorMessage)

        await runner.setShortcuts([first])
        await controller.performRefresh()
        controller.openInShortcuts(first.id)
        for _ in 0 ..< 100 {
            if !(await runner.observedViewNames()).isEmpty { break }
            await Task.yield()
        }

        viewNames = await runner.observedViewNames()
        XCTAssertEqual(viewNames, [first.name])
        XCTAssertNil(controller.snapshot.errorMessage)
    }

    private func makeController(
        runner: AppleShortcutsRunnerStub,
        visualMetadataLoader: any AppleShortcutsVisualMetadataLoading = AppleShortcutsVisualMetadataStub(),
        now: @escaping () -> Date = { .now }
    ) -> AppleShortcutsController {
        AppleShortcutsController(
            runner: runner,
            visualMetadataLoader: visualMetadataLoader,
            iconCache: AppleShortcutsIconCache(),
            localization: PluginLocalization(bundle: .main),
            now: now
        )
    }

}
