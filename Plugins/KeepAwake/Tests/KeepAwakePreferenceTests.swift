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

    private func storeVersion2Preferences(
        display: Bool,
        automaticLock: Bool,
        in storage: KeepAwakeMemoryStorage
    ) {
        storage.set(2, forKey: StorageKey.version)
        storage.set(display, forKey: StorageKey.keepDisplayOn)
        storage.set(automaticLock, forKey: StorageKey.preventAutomaticScreenLock)
    }

    private func storeCurrentBehavior(
        _ behavior: KeepAwakeBehavior,
        in storage: KeepAwakeMemoryStorage
    ) {
        storage.set(3, forKey: StorageKey.version)
        storage.set(behavior.rawValue, forKey: StorageKey.behavior)
    }

    func testBehaviorCapabilitiesAreHierarchical() {
        XCTAssertEqual(
            KeepAwakePreferences(behavior: .allowDisplayToTurnOff).capabilities,
            KeepAwakeCapabilities(
                preventDisplaySleep: false,
                preventAutomaticScreenLock: false,
                continueWithLidClosed: false,
                keepScreenBasedToolsWorking: false
            )
        )
        XCTAssertEqual(
            KeepAwakePreferences(behavior: .keepDisplayOn).capabilities,
            KeepAwakeCapabilities(
                preventDisplaySleep: true,
                preventAutomaticScreenLock: false,
                continueWithLidClosed: false,
                keepScreenBasedToolsWorking: false
            )
        )
        XCTAssertEqual(
            KeepAwakePreferences(behavior: .keepScreenBasedToolsWorking).capabilities,
            KeepAwakeCapabilities(
                preventDisplaySleep: true,
                preventAutomaticScreenLock: true,
                continueWithLidClosed: true,
                keepScreenBasedToolsWorking: true
            )
        )
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
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(factory.sessions.count, 1)
    }

    func testToggleActionReflectsAndChangesCurrentState() async throws {
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: KeepAwakeMemoryStorage())
        let toggle = try XCTUnwrap(
            plugin.actionCatalogEntries.first { $0.presentationState != nil }?.reference
        )

        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "切换阻止休眠")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)

        let startResult = try await plugin.beginAction(
            ActionInvocation(reference: toggle, source: .actionGrid, mode: .foreground)
        ).result()
        XCTAssertEqual(startResult, .succeeded())
        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "切换阻止休眠")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.subtitle, "不会自动停止")

        let stopResult = try await plugin.beginAction(
            ActionInvocation(reference: toggle, source: .actionGrid, mode: .foreground)
        ).result()
        XCTAssertEqual(stopResult, .succeeded())
        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "切换阻止休眠")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(
            Set(plugin.actionCatalogEntries.map(\.title)).count,
            plugin.actionCatalogEntries.count
        )
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
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
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

    func testAutomaticLockPreventionRunsOnDesktopAndOpenLidMac() {
        for state in [
            KeepAwakePowerSourceState(isPortableMac: false, isOnExternalPower: true),
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false,
                isLidClosed: false
            ),
        ] {
            let storage = KeepAwakeMemoryStorage()
            let factory = KeepAwakeSessionFactory(powerSourceState: state)
            let plugin = factory.makePlugin(storage: storage)
            plugin.setBehavior(.keepScreenBasedToolsWorking)

            plugin.handleAction(.setSwitch(true))

            XCTAssertTrue(factory.userActivityMaintainer.isActive)
            XCTAssertFalse(factory.virtualDisplayManager.isActive)
            XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
            XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates.last, false)
        }
    }

    func testAutomaticLockPreventionBundlesPoweredClosedLidServices() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)

        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates.last, true)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertTrue(factory.virtualDisplayManager.isActive)
    }

    func testSoftwareDisplayOnlyRunsWhileLidIsClosed() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: false
            )
        )
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        await settleAsyncState()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: false
            )
        )
        await settleAsyncState()

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
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
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "合盖运行已暂停 · 正在等待电源")

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

    func testLeavingScreenToolsStopsBundledServices() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        plugin.setBehavior(.allowDisplayToTurnOff)

        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertFalse(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates.last, false)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testStoppingSessionPreservesBehavior() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
    }

    func testPermanentSessionRestoresAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertNil(firstFactory.sessions[0].startedConfigurations.last?.endDate)

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
        )

        XCTAssertTrue(secondPlugin.primaryPanelState.isOn)
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

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertNotNil(firstFactory.sessions[0].startedConfigurations.last?.endDate)

        firstPlugin.deactivate(reason: .hostShutdown)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
        )

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testManualSwitchOffClearsPermanentRestoreState() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)

        firstPlugin.handleAction(.setSwitch(false))

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
        )

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
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

    func testKeepMacAwakeProfileMigratesToAllowDisplayOffBehavior() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(1, forKey: StorageKey.version)
        storage.set("keep-mac-awake", forKey: "awake-mode")
        storage.set(true, forKey: "custom-prevent-display-sleep")
        storage.set(true, forKey: "custom-prevent-automatic-screen-lock")

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
        XCTAssertNil(storage.values["awake-mode"])
        XCTAssertNil(storage.values["custom-prevent-display-sleep"])
        XCTAssertNil(storage.values["custom-prevent-automatic-screen-lock"])
    }

    func testScreenToolsProfileMigratesToScreenToolsBehavior() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(1, forKey: StorageKey.version)
        storage.set("screen-based-tools", forKey: "awake-mode")

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
    }

    func testCustomProfileAggregatesAdvancedCapabilities() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(1, forKey: StorageKey.version)
        storage.set("custom", forKey: "awake-mode")
        storage.set(false, forKey: "custom-prevent-display-sleep")
        storage.set(false, forKey: "custom-prevent-automatic-screen-lock")
        storage.set(true, forKey: "custom-continue-with-lid-closed")
        storage.set(false, forKey: "custom-keep-screen-based-tools-working")

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertNil(storage.values["custom-continue-with-lid-closed"])
    }

    func testVersion2PreferencesMigrateByCapabilityPriority() {
        let combinations: [(display: Bool, automaticLock: Bool, behavior: String)] = [
            (false, false, "allow-display-to-turn-off"),
            (true, false, "keep-display-on"),
            (false, true, "keep-screen-based-tools-working"),
            (true, true, "keep-screen-based-tools-working"),
        ]

        for combination in combinations {
            let storage = KeepAwakeMemoryStorage()
            storeVersion2Preferences(
                display: combination.display,
                automaticLock: combination.automaticLock,
                in: storage
            )

            _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

            XCTAssertEqual(
                storage.string(forKey: StorageKey.behavior),
                combination.behavior
            )
            XCTAssertNil(storage.values[StorageKey.keepDisplayOn])
            XCTAssertNil(storage.values[StorageKey.preventAutomaticScreenLock])
        }
    }

    func testRecognizedFuturePreferenceVersionIsHonoredWithoutRewritingStorage() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(99, forKey: StorageKey.version)
        storage.set(
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue,
            forKey: StorageKey.behavior
        )
        storage.set(true, forKey: "keep-awake-with-lid-closed")
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 99)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue
        )
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
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

    func testAutomaticRuntimeFallbackDoesNotRewriteFuturePreferencePayload() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(99, forKey: StorageKey.version)
        storage.set(
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue,
            forKey: StorageKey.behavior
        )
        storage.set(true, forKey: "keep-awake-with-lid-closed")
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        factory.userActivityMaintainer.startError = MockUserActivityError.declarationFailed
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法声明用户活动。")
        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 99)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue
        )
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
    }

    func testExplicitlyAcceptingFutureFallbackPersistsCurrentBehavior() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(99, forKey: StorageKey.version)
        storage.set(
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue,
            forKey: StorageKey.behavior
        )
        storage.set(true, forKey: "persistent-enabled")
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        factory.userActivityMaintainer.startError = MockUserActivityError.declarationFailed
        let plugin = factory.makePlugin(storage: storage)

        plugin.activate(context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage))

        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 99)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue
        )

        plugin.setBehavior(.keepDisplayOn)

        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 3)
        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")

        let relaunchedFactory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let relaunchedPlugin = relaunchedFactory.makePlugin(storage: storage)
        relaunchedPlugin.activate(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
        )

        XCTAssertTrue(relaunchedFactory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(relaunchedFactory.userActivityMaintainer.isActive)
    }

    func testCurrentBehaviorRemainsAuthoritativeAndCleansStaleSettings() {
        let storage = KeepAwakeMemoryStorage()
        storeCurrentBehavior(.allowDisplayToTurnOff, in: storage)
        storage.set("screen-based-tools", forKey: "awake-mode")
        storage.set(true, forKey: "custom-prevent-display-sleep")
        storage.set(true, forKey: "keep-awake-with-lid-closed")

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
        XCTAssertNil(storage.values["awake-mode"])
        XCTAssertNil(storage.values["custom-prevent-display-sleep"])
        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
    }

    func testInterruptedMigrationWithBehaviorPayloadCompletesSafely() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(
            KeepAwakeBehavior.keepScreenBasedToolsWorking.rawValue,
            forKey: StorageKey.behavior
        )

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 3)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
    }

    func testCurrentVersionWithoutBehaviorSelfHealsDefault() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(3, forKey: StorageKey.version)

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(storage.integer(forKey: StorageKey.version), 3)
        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
    }

    func testInvalidCurrentBehaviorRecoversLegacyBeforeCleanup() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(3, forKey: StorageKey.version)
        storage.set("invalid-behavior", forKey: StorageKey.behavior)
        storage.set(true, forKey: "keep-awake-with-lid-closed")

        _ = KeepAwakeSessionFactory().makePlugin(storage: storage)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
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
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法更新屏幕状态。")
    }

    func testInitialLidCloseFailureFallsBackWithoutStoppingBaseSession() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        factory.configureSession = {
            $0.lidCloseUpdateError = MockKeepAwakeSessionError.lidCloseUpdateFailed
        }
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(
            factory.sessions[0].startedConfigurations.last,
            MockKeepAwakeSession.Configuration(
                endDate: nil,
                preventDisplaySleep: false,
                preventLidCloseSleep: false
            )
        )
        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法更新合盖状态。")
    }

    func testUserActivityFailureFallsBackToKeepDisplayOn() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        factory.userActivityMaintainer.simulateFailure(
            MockUserActivityError.declarationFailed
        )
        await settleAsyncState()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
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
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法声明用户活动。")

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

    func testClosedLidPowerPauseRetriesFailedUserActivityCleanup() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()
        factory.userActivityMaintainer.stopError = MockUserActivityError.releaseFailed

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false,
                isLidClosed: true
            )
        )

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.refresh()

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        await settleAsyncState()

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
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.setBehavior(.keepDisplayOn)
        await settleAsyncState()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSessionEndReportsAndRefreshRetriesUserActivityRelease() {
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

        plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.refresh()

        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testFailedReenableKeepsCleanupFailureVisibleAndRetryable() {
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
        plugin.handleAction(.setSwitch(false))
        factory.configureSession = { session in
            session.startError = MockKeepAwakeSessionError.startFailed
        }

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.refresh()

        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testOffSessionBehaviorChangeRetriesPendingUserActivityRelease() {
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
        plugin.handleAction(.setSwitch(false))

        plugin.setBehavior(.allowDisplayToTurnOff)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.setBehavior(.allowDisplayToTurnOff)

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testVirtualDisplayFailureDoesNotCommitFallbackWhenUserActivityReleaseFails() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        factory.virtualDisplayManager.startError = MockVirtualDisplayError.creationFailed
        factory.userActivityMaintainer.stopError = MockUserActivityError.releaseFailed
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)

        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.refresh()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法创建软件显示器。")
    }

    func testVirtualDisplayTerminationDoesNotCommitFallbackWhenUserActivityReleaseFails() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()
        factory.userActivityMaintainer.stopError = MockUserActivityError.releaseFailed

        factory.virtualDisplayManager.simulateUnexpectedTermination()

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.userActivityMaintainer.stopError = nil
        plugin.refresh()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(
            plugin.primaryPanelState.errorMessage,
            "软件显示器已停止；已切换为保持屏幕常亮。"
        )
    }

    func testRuntimeFallbackDoesNotCommitWhenUserActivityReleaseFails() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()
        factory.sessions[0].displayUpdateError = MockKeepAwakeSessionError.displayUpdateFailed
        factory.userActivityMaintainer.stopError = MockUserActivityError.releaseFailed

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false,
                isLidClosed: true
            )
        )

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "keep-screen-based-tools-working"
        )
        XCTAssertTrue(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法恢复自动锁定。")

        factory.sessions[0].displayUpdateError = nil
        factory.userActivityMaintainer.stopError = nil
        plugin.refresh()

        XCTAssertEqual(
            storage.string(forKey: StorageKey.behavior),
            "allow-display-to-turn-off"
        )
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法更新屏幕状态。")
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
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法创建软件显示器。")
    }

    func testUnexpectedVirtualDisplayTerminationFallsBackToKeepDisplayOn() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        factory.virtualDisplayManager.simulateUnexpectedTermination()

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), "keep-display-on")
        XCTAssertFalse(factory.userActivityMaintainer.isActive)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
    }

    func testPhysicalExternalDisplaySuppressesOnlySoftwareDisplay() async {
        let builtIn = display(id: 1, name: "Built-in Display", isBuiltin: true)
        let external = display(
            id: 2,
            name: "Studio Display",
            isBuiltin: false,
            vendorNumber: 0x610
        )
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(displays: [builtIn, external])
        let plugin = factory.makePlugin(storage: storage)
        plugin.setBehavior(.keepScreenBasedToolsWorking)
        plugin.handleAction(.setSwitch(true))
        await settleAsyncState()

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertTrue(factory.userActivityMaintainer.isActive)

        factory.displayProvider.displays = [builtIn]
        plugin.refreshDisplayTopology()
        await settleAsyncState()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
    }

    func testSearchExposesSingleBehaviorChoice() {
        let plugin = KeepAwakeSessionFactory()
            .makePlugin(storage: KeepAwakeMemoryStorage())

        guard case let .form(sections) = plugin.settingsPage?.body,
              case let .rows(rows) = sections.first?.content else {
            return XCTFail("Expected declarative settings rows")
        }

        XCTAssertEqual(rows.map(\.id), [KeepAwakeSettingsSearchEntryID.behavior])
        guard case let .choiceGroup(_, options) = rows[0].control
        else {
            return XCTFail("Expected the behavior choices to use a visible choice group")
        }
        XCTAssertEqual(options.count, KeepAwakeBehavior.allCases.count)
        XCTAssertEqual(options.map(\.descriptionTone), [.neutral, .neutral, .caution])
    }

    func testScreenToolsSettingsExposeCautionWarningsAsSeparateItems() throws {
        let plugin = KeepAwakeSessionFactory()
            .makePlugin(storage: KeepAwakeMemoryStorage())
        plugin.setBehavior(.keepScreenBasedToolsWorking)

        guard case let .form(sections) = try XCTUnwrap(plugin.settingsPage).body,
              case let .rows(rows) = try XCTUnwrap(sections.first?.content)
        else {
            return XCTFail("Expected declarative settings rows")
        }
        let row = try XCTUnwrap(rows.first)

        XCTAssertNil(row.help)
        XCTAssertEqual(row.helpTone, .caution)
        XCTAssertEqual(row.helpItems.count, 4)
        XCTAssertTrue(row.helpItems.allSatisfy { !$0.contains("\n") })
    }

    func testFeaturePanelExposesBehaviorChoicesWhileKeepAwakeIsEnabled() throws {
        let storage = KeepAwakeMemoryStorage()
        let plugin = KeepAwakeSessionFactory().makePlugin(storage: storage)
        plugin.handleAction(.setSwitch(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.map(\.id), ["duration", "behavior"])
        XCTAssertEqual(controls[0].selectedOptionID, "forever")
        XCTAssertFalse(controls[0].showsLeadingDivider)
        guard case .selectList = controls[1].kind else {
            return XCTFail("Expected behavior choices to use a selectable menu-bar list")
        }
        XCTAssertEqual(
            controls[1].options.map(\.id),
            KeepAwakeBehavior.allCases.map(\.rawValue)
        )
        XCTAssertEqual(controls[1].selectedOptionID, KeepAwakeBehavior.allowDisplayToTurnOff.rawValue)
        XCTAssertTrue(controls[1].showsLeadingDivider)
    }

    func testFeaturePanelBehaviorSelectionUpdatesAnActiveSession() throws {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let plugin = factory.makePlugin(storage: storage)
        plugin.handleAction(.setSwitch(true))

        plugin.handleAction(.setSelection(
            controlID: "behavior",
            optionID: KeepAwakeBehavior.keepDisplayOn.rawValue
        ))

        XCTAssertEqual(storage.string(forKey: StorageKey.behavior), KeepAwakeBehavior.keepDisplayOn.rawValue)
        XCTAssertTrue(factory.sessions[0].isPreventingDisplaySleep)
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.last?.selectedOptionID,
            KeepAwakeBehavior.keepDisplayOn.rawValue
        )
    }

    func testCompactBadgeReflectsHighestPriorityActivePreference() throws {
        XCTAssertNil(compactIndicator(behavior: .allowDisplayToTurnOff))

        let displayIndicator = try XCTUnwrap(
            compactIndicator(behavior: .keepDisplayOn)
        )
        XCTAssertEqual(displayIndicator.icons.count, 1)
        XCTAssertEqual(displayIndicator.icons[0].systemImage, "display")
        XCTAssertEqual(displayIndicator.icons[0].label, "屏幕常亮")

        let screenToolsIndicator = try XCTUnwrap(
            compactIndicator(behavior: .keepScreenBasedToolsWorking)
        )
        XCTAssertEqual(screenToolsIndicator.icons.count, 1)
        XCTAssertEqual(screenToolsIndicator.icons[0].label, "屏幕工具")

    }

    func testCompactBadgeIsHiddenWhileKeepAwakeIsOff() {
        let plugin = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        ).makePlugin(storage: KeepAwakeMemoryStorage())
        plugin.setBehavior(.keepDisplayOn)

        XCTAssertNil(plugin.primaryPanelCompactIndicator)
    }

    func testTimedSessionKeepsEndDateWhenPreferenceChanges() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)
        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSelection(controlID: "duration", optionID: "oneHour"))
        let endDate = factory.sessions[0].startedConfigurations.last?.endDate

        plugin.setBehavior(.keepDisplayOn)

        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.endDate, endDate)
        XCTAssertNotNil(endDate)
    }

    private func compactIndicator(
        behavior: KeepAwakeBehavior
    ) -> PluginPrimaryPanelCompactIndicator? {
        let plugin = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        ).makePlugin(storage: KeepAwakeMemoryStorage())
        plugin.setBehavior(behavior)
        plugin.handleAction(.setSwitch(true))
        return plugin.primaryPanelCompactIndicator
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

    func testRepeatedStartDoesNotDuplicateTimersOrDeclarations() throws {
        var declarationCount = 0
        let maintainer = KeepAwakeUserActivityMaintainer(
            localization: PluginLocalization(bundle: .main),
            refreshInterval: 60,
            activityDeclarer: { assertionID in
                declarationCount += 1
                assertionID = 7
                return kIOReturnSuccess
            },
            assertionReleaser: { _ in kIOReturnSuccess }
        )

        try maintainer.start()
        try maintainer.start()

        XCTAssertEqual(declarationCount, 1)
        try maintainer.stop()
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

    func testFailedRefreshPreservesPreviousAssertionForReleaseRetry() async throws {
        var declarationCount = 0
        var releaseResults = [kIOReturnError, kIOReturnSuccess]
        var releasedIDs: [IOPMAssertionID] = []
        let refreshFailure = expectation(description: "refresh failure reported")
        let maintainer = KeepAwakeUserActivityMaintainer(
            localization: PluginLocalization(bundle: .main),
            refreshInterval: 0.01,
            activityDeclarer: { assertionID in
                declarationCount += 1
                if declarationCount == 1 {
                    assertionID = 42
                    return kIOReturnSuccess
                }

                assertionID = 0
                return kIOReturnError
            },
            assertionReleaser: { assertionID in
                releasedIDs.append(assertionID)
                return releaseResults.removeFirst()
            }
        )
        maintainer.onFailure = { _ in
            refreshFailure.fulfill()
        }

        try maintainer.start()
        await fulfillment(of: [refreshFailure], timeout: 1)

        XCTAssertTrue(maintainer.isActive)
        XCTAssertEqual(releasedIDs, [42])

        try maintainer.stop()

        XCTAssertFalse(maintainer.isActive)
        XCTAssertEqual(releasedIDs, [42, 42])
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
