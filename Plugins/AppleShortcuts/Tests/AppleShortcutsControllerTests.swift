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

    func testRefreshAppliesVisualMetadataToDiscoveredShortcut() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Colored")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let controller = makeController(
            runner: AppleShortcutsRunnerStub(shortcuts: [item]),
            visualMetadataLoader: AppleShortcutsVisualMetadataStub(result: .success([item.id: metadata]))
        )

        await controller.performRefresh()

        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [AppleShortcutItem(
            id: item.id,
            name: item.name,
            visualMetadata: metadata
        )])
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

    func testFailedUnsyncedFolderMembershipPreservesPreviousDiscovery() async {
        let folder = AppleShortcutFolder(id: UUID(), name: "Ordinary")
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
        XCTAssertEqual(controller.snapshot.discovery.failedFolderIDs, [folder.id])
        XCTAssertNotNil(controller.snapshot.errorMessage)
    }

    func testConcurrentRefreshRequestsCoalesce() async throws {
        let runner = AppleShortcutsRunnerStub(delay: .milliseconds(100))
        let controller = makeController(runner: runner)

        controller.refresh(force: true)
        controller.refresh(force: true)
        try await Task.sleep(for: .milliseconds(350))

        let callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRefreshIfNeededRespectsFreshnessWindowBoundary() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let runner = AppleShortcutsRunnerStub()
        let controller = makeController(runner: runner, now: { currentDate })
        await controller.performRefresh()

        currentDate.addTimeInterval(AppleShortcutsController.freshnessInterval - 1)
        controller.refreshIfNeeded()
        for _ in 0 ..< 20 { await Task.yield() }
        var callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 1)

        currentDate.addTimeInterval(1)
        controller.refreshIfNeeded()
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 2 { break }
            await Task.yield()
        }
        callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 2)
    }

    func testActivationTriggersOnlyOneInitialRefresh() async throws {
        let runner = AppleShortcutsRunnerStub()
        let controller = makeController(runner: runner)

        controller.activate()
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initialCallCount = await runner.observedListCallCount()
        XCTAssertEqual(initialCallCount, 1)

        try await Task.sleep(for: .milliseconds(60))
        let finalCallCount = await runner.observedListCallCount()
        XCTAssertEqual(finalCallCount, 1)
        controller.deactivate()
    }

    func testBackgroundRefreshOnlyLoadsShortcutNamesAndIdentifiers() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Folder")
        let item = AppleShortcutItem(id: UUID(), name: "Background")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [folder],
            memberships: [folder.id: .success([item])]
        )
        let visualMetadataLoader = AppleShortcutsVisualMetadataCountingStub(result: .success([:]))
        let controller = makeController(
            runner: runner,
            visualMetadataLoader: visualMetadataLoader
        )

        controller.refresh(force: true)
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 1 { break }
            await Task.yield()
        }

        let shortcutListCallCount = await runner.observedListCallCount()
        let folderListCallCount = await runner.observedFolderListCallCount()
        let membershipCallIDs = await runner.observedMembershipCallIDs()
        let visualMetadataCallCount = await visualMetadataLoader.observedCallCount()
        XCTAssertEqual(shortcutListCallCount, 1)
        XCTAssertEqual(folderListCallCount, 0)
        XCTAssertTrue(membershipCallIDs.isEmpty)
        XCTAssertEqual(visualMetadataCallCount, 0)
        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [item])
    }

    func testSettingsRefreshLoadsFoldersAndVisualMetadataAfterBackgroundRefresh() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Visual")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let runner = AppleShortcutsRunnerStub(shortcuts: [item])
        let visualMetadataLoader = AppleShortcutsVisualMetadataCountingStub(
            result: .success([item.id: metadata])
        )
        let controller = makeController(
            runner: runner,
            visualMetadataLoader: visualMetadataLoader
        )

        controller.refresh(force: true)
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 1 { break }
            await Task.yield()
        }
        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if controller.snapshot.discovery.shortcuts.first?.visualMetadata == metadata { break }
            await Task.yield()
        }

        let shortcutListCallCount = await runner.observedListCallCount()
        let folderListCallCount = await runner.observedFolderListCallCount()
        let visualMetadataCallCount = await visualMetadataLoader.observedCallCount()
        XCTAssertEqual(shortcutListCallCount, 2)
        XCTAssertEqual(folderListCallCount, 1)
        XCTAssertEqual(visualMetadataCallCount, 1)
        XCTAssertEqual(controller.snapshot.discovery.shortcuts.first?.visualMetadata, metadata)
    }

    func testLightRefreshInvalidatesSettingsFreshnessWhenLibraryChanges() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let first = AppleShortcutItem(id: UUID(), name: "First")
        let second = AppleShortcutItem(id: UUID(), name: "Second")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let runner = AppleShortcutsRunnerStub(shortcuts: [first])
        let visualMetadataLoader = AppleShortcutsVisualMetadataCountingStub(
            result: .success([first.id: metadata, second.id: metadata])
        )
        let controller = makeController(
            runner: runner,
            visualMetadataLoader: visualMetadataLoader,
            now: { currentDate }
        )

        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if controller.snapshot.discovery.shortcuts.first?.visualMetadata == metadata { break }
            await Task.yield()
        }
        controller.setSettingsVisible(false)
        await runner.setShortcuts([first, second])
        currentDate.addTimeInterval(10)
        controller.refresh(force: true)
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 2 { break }
            await Task.yield()
        }

        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if controller.snapshot.discovery.shortcuts.count == 2,
               controller.snapshot.discovery.shortcuts.last?.visualMetadata == metadata { break }
            await Task.yield()
        }

        let visualMetadataCallCount = await visualMetadataLoader.observedCallCount()
        XCTAssertEqual(visualMetadataCallCount, 2)
        XCTAssertEqual(controller.snapshot.discovery.shortcuts.map(\.id), [first.id, second.id])
        XCTAssertEqual(controller.snapshot.discovery.shortcuts.last?.visualMetadata, metadata)
    }

    func testHidingSettingsCancelsRichRefreshAndDiscardsItsResult() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Hidden")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let visualMetadataLoader = AppleShortcutsVisualMetadataDelayedStub(
            result: .success([item.id: metadata]),
            delay: .milliseconds(100)
        )
        let controller = makeController(
            runner: AppleShortcutsRunnerStub(shortcuts: [item]),
            visualMetadataLoader: visualMetadataLoader
        )

        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if await visualMetadataLoader.observedCallCount() == 1 { break }
            await Task.yield()
        }
        controller.setSettingsVisible(false)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(controller.snapshot.discovery.shortcuts.isEmpty)
        XCTAssertNil(controller.snapshot.lastSettingsRefresh)
        XCTAssertFalse(controller.snapshot.isRefreshing)
    }

    func testVisibleSettingsLoadsIconsOnDemand() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Icon")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let iconData = Data([0x01, 0x02])
        let visualMetadataLoader = AppleShortcutsVisualMetadataCountingStub(
            result: .success([item.id: metadata]),
            iconResult: .success(iconData)
        )
        let controller = makeController(
            runner: AppleShortcutsRunnerStub(shortcuts: [item]),
            visualMetadataLoader: visualMetadataLoader
        )

        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if controller.snapshot.discovery.shortcuts.first?.visualMetadata == metadata { break }
            await Task.yield()
        }
        controller.requestIcon(for: item.id)
        for _ in 0 ..< 100 {
            if controller.cachedIconData(for: item.id) == iconData { break }
            await Task.yield()
        }

        let iconCallCount = await visualMetadataLoader.observedIconCallCount()
        XCTAssertEqual(iconCallCount, 1)
        XCTAssertEqual(controller.cachedIconData(for: item.id), iconData)
    }

    func testHidingSettingsDiscardsCachedIcons() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Icon")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let iconData = Data([0x01, 0x02])
        let visualMetadataLoader = AppleShortcutsVisualMetadataCountingStub(
            result: .success([item.id: metadata]),
            iconResult: .success(iconData)
        )
        let controller = makeController(
            runner: AppleShortcutsRunnerStub(shortcuts: [item]),
            visualMetadataLoader: visualMetadataLoader
        )

        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if controller.snapshot.discovery.shortcuts.first?.visualMetadata == metadata { break }
            await Task.yield()
        }
        controller.requestIcon(for: item.id)
        for _ in 0 ..< 100 {
            if controller.cachedIconData(for: item.id) == iconData { break }
            await Task.yield()
        }
        XCTAssertEqual(controller.cachedIconData(for: item.id), iconData)

        controller.setSettingsVisible(false)

        XCTAssertNil(controller.cachedIconData(for: item.id))
    }

    func testFailedIconLoadIsNotRetriedUntilSettingsRefresh() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Broken")
        let metadata = AppleShortcutVisualMetadata(color: .init(red: 0.25, green: 0.5, blue: 0.75))
        let visualMetadataLoader = AppleShortcutsVisualMetadataCountingStub(
            result: .success([item.id: metadata]),
            iconResult: .failure(.automationUnavailable)
        )
        let controller = makeController(
            runner: AppleShortcutsRunnerStub(shortcuts: [item]),
            visualMetadataLoader: visualMetadataLoader
        )

        controller.setSettingsVisible(true)
        for _ in 0 ..< 100 {
            if controller.snapshot.discovery.shortcuts.first?.visualMetadata == metadata { break }
            await Task.yield()
        }
        controller.requestIcon(for: item.id)
        for _ in 0 ..< 100 {
            if await visualMetadataLoader.observedIconCallCount() == 1 { break }
            await Task.yield()
        }

        // Simulates a list row disappearing and reappearing (e.g. scrolling), which recreates the
        // icon view and re-triggers its `.task`.
        controller.requestIcon(for: item.id)
        controller.requestIcon(for: item.id)
        for _ in 0 ..< 20 { await Task.yield() }

        let iconCallCount = await visualMetadataLoader.observedIconCallCount()
        XCTAssertEqual(iconCallCount, 1)
        XCTAssertNil(controller.cachedIconData(for: item.id))
    }

    func testMembershipQueriesRespectConcurrencyLimit() async throws {
        let folders = (0 ..< 9).map {
            AppleShortcutFolder(id: UUID(), name: "Folder \($0)")
        }
        let runner = AppleShortcutsRunnerStub(
            folders: folders,
            membershipDelay: .milliseconds(40)
        )
        let controller = makeController(runner: runner)

        await controller.performRefresh()

        let observedMaximum = await runner.observedMaximumConcurrentMembershipCallCount()
        XCTAssertEqual(
            observedMaximum,
            AppleShortcutsController.maximumConcurrentMembershipQueries
        )
        XCTAssertEqual(controller.snapshot.discovery.folderMemberships.count, folders.count)
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

    func testAppliedRefreshNotifiesHostExactlyOnce() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Observed")
        let item = AppleShortcutItem(id: UUID(), name: "Item")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [folder],
            memberships: [folder.id: .success([item])]
        )
        let controller = makeController(runner: runner)
        var notificationCount = 0
        controller.onStateChange = { notificationCount += 1 }

        await controller.performRefresh()

        XCTAssertEqual(notificationCount, 1)
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

    func testCancelledTaskCannotRegisterExecution() async {
        let shortcutID = UUID()
        let runner = AppleShortcutsRunnerStub()
        let controller = makeController(runner: runner)
        let registrationTask = Task { @MainActor in
            controller.startExecution(shortcutID: shortcutID, name: "Cancelled")
        }
        registrationTask.cancel()

        let registrationResult = await registrationTask.value
        let runIDs = await runner.observedRunIDs()

        XCTAssertThrowsError(try registrationResult.get()) { error in
            XCTAssertEqual(error as? AppleShortcutsExecutionStartError, .cancelled)
        }
        XCTAssertFalse(controller.isRunning(shortcutID))
        XCTAssertTrue(runIDs.isEmpty)
    }

    func testDeactivationPreventsLateRefreshFromOverwritingReactivatedState() async throws {
        let old = AppleShortcutItem(id: UUID(), name: "Old")
        let new = AppleShortcutItem(id: UUID(), name: "New")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [old],
            delay: .milliseconds(120),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        controller.refresh(force: true)
        try await Task.sleep(for: .milliseconds(20))

        controller.deactivate()
        await runner.setShortcuts([new])
        controller.activate()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [new])
    }

    func testDeactivationClearsRefreshingStateWhenFreshSnapshotSkipsReactivationRefresh() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Fresh")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            delay: .milliseconds(120),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        controller.refresh(force: true)
        for _ in 0 ..< 100 where !controller.snapshot.isRefreshing {
            await Task.yield()
        }
        XCTAssertTrue(controller.snapshot.isRefreshing)

        controller.deactivate()
        controller.activate()

        XCTAssertFalse(controller.snapshot.isRefreshing)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.snapshot.isRefreshing)
        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [item])
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

    func testDeactivationCancelsViewAndRejectsLatePresentation() async throws {
        let shortcutID = UUID()
        let item = AppleShortcutItem(id: shortcutID, name: "Late View")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            delay: .milliseconds(100),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        controller.presentStoreError(.invalidData)
        controller.openInShortcuts(shortcutID)
        for _ in 0 ..< 100 {
            if !(await runner.observedViewNames()).isEmpty { break }
            await Task.yield()
        }

        controller.deactivate()
        XCTAssertNil(controller.snapshot.errorMessage)
        XCTAssertNil(controller.snapshot.operationMessage)
        controller.activate()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertNil(controller.snapshot.errorMessage)
        XCTAssertNil(controller.snapshot.operationMessage)
        let viewNames = await runner.observedViewNames()
        XCTAssertEqual(viewNames, [item.name])
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
            iconCache: AppleShortcutsIconCache(cache: ControlledIconCache()),
            localization: PluginLocalization(bundle: .main),
            now: now
        )
    }
}
