import AppKit
import XCTest
import IOKit.pwr_mgt
import MacToolsPluginKit
@testable import KeepAwakePlugin

private enum MockUserActivityError: LocalizedError {
    case declarationFailed
    case releaseFailed

    var errorDescription: String? {
        switch self {
        case .declarationFailed:
            "无法声明用户活动。"
        case .releaseFailed:
            "无法恢复自动锁定。"
        }
    }
}

@MainActor
final class KeepAwakePreferenceTests: XCTestCase {
    private enum StorageKey {
        static let version = "behavior-preference-version"
        static let behavior = "display-behavior"
        static let keepDisplayOn = "keep-display-on"
        static let preventAutomaticScreenLock = "prevent-automatic-screen-lock"
    }

    private func settleAsyncState() async {
        for _ in 0..<6 {
            await Task.yield()
        }
    }

    private func display(
        id: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        vendorNumber: UInt32? = nil
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            name: name,
            isBuiltin: isBuiltin,
            isMain: isBuiltin,
            vendorNumber: vendorNumber,
            modelNumber: nil,
            serialNumber: nil
        )
    }

    private func storeCurrentBehavior(
        _ behavior: KeepAwakeBehavior,
        in storage: KeepAwakeMemoryStorage
    ) {
        storage.set(3, forKey: StorageKey.version)
        storage.set(behavior.rawValue, forKey: StorageKey.behavior)
    }

    func testDefaultSessionOnlyPreventsSystemIdleSleep() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: false
            )
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(
            factory.sessions[0].startedConfigurations.last,
            MockKeepAwakeSession.Configuration(
                endDate: nil,
                preventDisplaySleep: false,
                preventLidCloseSleep: false
            )
        )
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
    }

    func testIdempotentActionEnablesKeepAwakeThroughSessionFactory() async throws {
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: KeepAwakeMemoryStorage())
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first { $0.title == "无限期阻止休眠" }?.reference
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), [
            "切换阻止休眠",
            "无限期阻止休眠",
            "停用阻止休眠",
            "阻止休眠 · 30min",
            "阻止休眠 · 1h",
            "阻止休眠 · 2h",
            "阻止休眠 · 5h",
        ])
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertEqual(factory.sessions.count, 1)
    }

    func testCanonicalStopFailsWhenAutomaticLockCleanupFails() async throws {
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: KeepAwakeMemoryStorage())
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        factory.userActivityMaintainer.stopError = MockUserActivityError.releaseFailed
        let stop = try XCTUnwrap(
            plugin.actionCatalogEntries.first { $0.title == "停用阻止休眠" }?.reference
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: stop,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected cleanup failure, got \(result)")
        }
        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testDurationActionsStartBoundedKeepAwakeSessions() async throws {
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: KeepAwakeMemoryStorage())
        let oneHour = try XCTUnwrap(
            plugin.actionCatalogEntries.first { $0.title == "阻止休眠 · 1h" }?.reference
        )
        let before = Date()

        let result = try await plugin.beginAction(
            ActionInvocation(reference: oneHour, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        let endDate = try XCTUnwrap(factory.sessions.first?.startedConfigurations.last?.endDate)
        XCTAssertEqual(endDate.timeIntervalSince(before), 60 * 60, accuracy: 2)
    }

    func testBehaviorCanBeChangedWhileRunning() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)
        plugin.handleAction(.setSwitch(true))

        plugin.setBehavior(.keepDisplayOn)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")

        plugin.setBehavior(.allowDisplayToTurnOff)
        XCTAssertFalse(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
    }

    func testClosedLidServicesPauseOnBatteryAndResumeOnPower() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false,
                isLidClosed: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertEqual(plugin.rowState.subtitle, "合盖运行已暂停 · 正在等待电源")

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        await settleAsyncState()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
    }

    func testPermanentSessionRestoresAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))

        XCTAssertTrue(firstPlugin.rowState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertNil(firstFactory.sessions[0].startedConfigurations.last?.endDate)

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.rowState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
        )

        XCTAssertTrue(secondPlugin.rowState.isOn)
        XCTAssertEqual(secondFactory.sessions.count, 1)
        XCTAssertNil(secondFactory.sessions[0].startedConfigurations.last?.endDate)
    }

    func testTemporarySessionDoesNotRestoreAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        firstPlugin.handleAction(
            .setSelection(controlID: "duration", optionID: "oneHour")
        )

        XCTAssertTrue(firstPlugin.rowState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertNotNil(firstFactory.sessions[0].startedConfigurations.last?.endDate)

        firstPlugin.deactivate(reason: .hostShutdown)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
        )

        XCTAssertFalse(secondPlugin.rowState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testPreferencesPersistAcrossRelaunch() async {
        let storage = KeepAwakeMemoryStorage()
        let firstPlugin = KeepAwakeSessionFactory().makePlugin(storage: storage)
        firstPlugin.setBehavior(.keepScreenBasedToolsWorking)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        XCTAssertTrue(secondFactory.sessions[0].isPreventingDisplaySleep)
        XCTAssertTrue(secondFactory.userActivityMaintainer.isActive)
        XCTAssertTrue(secondFactory.virtualDisplayManager.isActive)
    }

    func testReleasedSettingsMigrateIntoBehaviorLevels() {
        let combinations: [(display: Bool, lid: Bool, virtualDisplay: Bool)] = [
            (false, false, false),
            (true, false, false),
            (false, true, false),
            (true, true, false),
            (false, false, true),
            (true, false, true),
            (false, true, true),
            (true, true, true),
        ]

        for combination in combinations {
            let storage = KeepAwakeMemoryStorage()
            storage.set(combination.display, forKey: "keep-display-on")
            storage.set(combination.lid, forKey: "keep-awake-with-lid-closed")
            storage.set(
                combination.virtualDisplay,
                forKey: "keep-desktop-available-with-lid-closed"
            )

            _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

            XCTAssertEqual(storage.integer(forKey: StorageKey.version), 3)
            XCTAssertEqual(
                storage.string(forKey: StorageKey.behavior),
                combination.lid || combination.virtualDisplay
                    ? "keep-screen-based-tools-working"
                    : combination.display
                        ? "keep-display-on"
                        : "allow-display-to-turn-off"
            )
            XCTAssertNil(storage.values[StorageKey.keepDisplayOn])
            XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
            XCTAssertNil(storage.values["keep-desktop-available-with-lid-closed"])
        }
    }

    func testUnknownFuturePreferenceVersionFallsBackWithoutDestroyingFutureData() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(99, forKey: StorageKey.version)
        storage.set("future-behavior", forKey: StorageKey.behavior)
        storage.set(true, forKey: "custom-continue-with-lid-closed")
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 99)
        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "future-behavior")
        XCTAssertEqual(storage.values["custom-continue-with-lid-closed"] as? Bool, true)
    }

    func testDisplayFailureFallsBackToAllowDisplayOff() async {
        let storage = KeepAwakeMemoryStorage()
        storeCurrentBehavior(.keepScreenBasedToolsWorking, in: storage)
        storage.set(true, forKey: "persistent-enabled")
        let factory = KeepAwakeSessionFactory()
        factory.configureSession = {
            $0.appliesDisplaySleepPreventionDuringStart = false
            $0.displayUpdateError = MockKeepAwakeSessionError.displayUpdateFailed
        }
        let plugin = factory.makePlugin(storage: storage)

        plugin.activate(context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage))
        await settleAsyncState()

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertEqual(plugin.rowState.errorMessage, "无法更新屏幕状态。")
    }

    func testFailedBehaviorUpdateRestoresPreviousPreferenceAndCanRetry() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepDisplayOn)
        plugin.handleAction(.setSwitch(true))
        factory.userActivityMaintainer.startError = MockUserActivityError.declarationFailed

        plugin.setBehavior(.keepScreenBasedToolsWorking)

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.rowState.errorMessage, "无法声明用户活动。")

        factory.userActivityMaintainer.startError = nil
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        await settleAsyncState()

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertTrue(factory.virtualDisplayManager.isActive)
    }

    func testFailedUserActivityReleaseKeepsScreenToolsSelectedAndCanRetry() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        factory.userActivityMaintainer.stopError = MockUserActivityError.releaseFailed

        plugin.setBehavior(.keepDisplayOn)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.rowState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.setBehavior(.keepDisplayOn)
        await settleAsyncState()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testVirtualDisplayFailureFallsBackToKeepDisplayOn() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        factory.virtualDisplayManager.startError = MockVirtualDisplayError.creationFailed
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)

        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.rowState.errorMessage, "无法创建软件显示器。")
    }

}

@MainActor
final class KeepAwakeUserActivityMaintainerTests: XCTestCase {
    func testStartReportsImmediatelyAndStopReleasesLatestAssertion() throws {
        var reportedIDs: [IOPMAssertionID] = []
        var releasedIDs: [IOPMAssertionID] = []
        let maintainer = KeepAwakeUserActivityMaintainer(
            localization: PluginLocalization(bundle: .main),
            refreshInterval: 60,
            activityDeclarer: { assertionID in
                assertionID = 42
                reportedIDs.append(assertionID)
                return kIOReturnSuccess
            },
            assertionReleaser: { assertionID in
                releasedIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try maintainer.start()
        XCTAssertTrue(maintainer.isActive)
        XCTAssertEqual(reportedIDs, [42])

        try maintainer.stop()
        XCTAssertFalse(maintainer.isActive)
        XCTAssertEqual(releasedIDs, [42])
    }

    func testFailedReleaseRetainsAssertionForRetry() throws {
        var releaseResults = [kIOReturnError, kIOReturnSuccess]
        var releasedIDs: [IOPMAssertionID] = []
        let localization = PluginLocalization(bundle: .main)
        let maintainer = KeepAwakeUserActivityMaintainer(
            localization: localization,
            refreshInterval: 60,
            activityDeclarer: { assertionID in
                assertionID = 42
                return kIOReturnSuccess
            },
            assertionReleaser: { assertionID in
                releasedIDs.append(assertionID)
                return releaseResults.removeFirst()
            }
        )

        try maintainer.start()
        XCTAssertThrowsError(try maintainer.stop()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                localization.format(
                    "error.automaticLock.userActivityReleaseFailedFormat",
                    defaultValue: "无法恢复自动锁定，系统返回错误 %d。自动锁定可能仍被阻止。",
                    kIOReturnError
                )
            )
        }
        XCTAssertTrue(maintainer.isActive)
        try maintainer.stop()

        XCTAssertEqual(releasedIDs, [42, 42])
        XCTAssertFalse(maintainer.isActive)
    }

    func testInitialDeclarationFailureDoesNotStartMaintainer() {
        let maintainer = KeepAwakeUserActivityMaintainer(
            localization: PluginLocalization(bundle: .main),
            refreshInterval: 60,
            activityDeclarer: { _ in kIOReturnError }
        )

        XCTAssertThrowsError(try maintainer.start())
        XCTAssertFalse(maintainer.isActive)
    }
}
