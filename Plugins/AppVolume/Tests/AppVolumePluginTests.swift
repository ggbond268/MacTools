import CoreAudio
import XCTest
import MacToolsPluginKit
@testable import AppVolumePlugin
@testable import MacTools

@MainActor
final class AppVolumePluginTests: XCTestCase {
    func testManifestDynamicActionMatchesRuntimePolicy() throws {
        let plugin = makePlugin()

        try PluginManifestActionAssertions.assertConsistency(
            pluginDirectoryName: "AppVolume",
            definitions: plugin.actionDefinitions,
            permissionIDs: plugin.permissionRequirementIDs(for:)
        )
    }

    func testMetadataAndPermissionRequirement() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "app-volume")
        XCTAssertEqual(plugin.metadata.title, "应用音量")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .disclosure)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["system-audio-recording"])
    }

    func testPanelShowsSliderForEachPlayingApplication() {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))

        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 41),
            application(id: "com.example.browser", name: "Browser", objectID: 42),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))

        let state = plugin.primaryPanelState
        let sliders = state.detail?.controls.filter { $0.kind == .slider } ?? []
        XCTAssertEqual(sliders.map(\.sectionTitle), ["Browser", "Music"])
        XCTAssertEqual(sliders.compactMap(\.sliderValue), [1, 1])
        XCTAssertEqual(sliders.map(\.valueLabel), ["100%", "100%"])
        XCTAssertEqual(state.subtitle, "2 个应用正在播放")
    }

    func testChangingSliderRequestsAccessAndRoutesTarget() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 51),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.35, phase: .ended))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(router.accessRequestCount, 1)
        let target = try XCTUnwrap(router.lastTargets.first)
        XCTAssertEqual(target.id, "com.example.music")
        XCTAssertEqual(target.gain, 0.35, accuracy: 0.001)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testReturningSliderToUnityStopsProcessing() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 61),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.5, phase: .ended))
        for _ in 0 ..< 100 {
            let control = plugin.primaryPanelState.detail?.controls.first
            if !router.updates.isEmpty,
               control?.sliderValue == 0.5,
               control?.isEnabled == true {
                break
            }
            await Task.yield()
        }
        plugin.handleAction(.setSlider(controlID: sliderID, value: 1, phase: .ended))
        for _ in 0 ..< 100 {
            if !plugin.primaryPanelState.isOn,
               plugin.primaryPanelState.detail?.controls.first?.isEnabled == true {
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(router.lastTargets.isEmpty)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testVolumePreferenceIsRestoredForMatchingApplication() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock()
        let firstPlugin = makePlugin(storage: storage, monitor: monitor, router: router)
        firstPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 71),
        ]))
        firstPlugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(firstPlugin.primaryPanelState.detail?.controls.first?.id)
        firstPlugin.handleAction(.setSlider(controlID: sliderID, value: 0.2, phase: .ended))
        for _ in 0 ..< 100 where router.updates.isEmpty {
            await Task.yield()
        }
        await Task.yield()

        let secondMonitor = AppVolumeMonitorMock()
        let secondPlugin = makePlugin(storage: storage, monitor: secondMonitor)
        secondPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        secondMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 72),
        ]))
        secondPlugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertEqual(secondPlugin.primaryPanelState.detail?.controls.first?.sliderValue, 0.2)
    }

    func testRestoredVolumeDoesNotRequestAccessUntilUserChangesIt() async throws {
        let storage = AppVolumeStorageMock()
        let firstMonitor = AppVolumeMonitorMock()
        let firstPlugin = makePlugin(storage: storage, monitor: firstMonitor)
        firstPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        firstMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 81),
        ]))
        firstPlugin.handleAction(.setDisclosureExpanded(true))
        let firstSliderID = try XCTUnwrap(firstPlugin.primaryPanelState.detail?.controls.first?.id)
        firstPlugin.handleAction(.setSlider(controlID: firstSliderID, value: 0.2, phase: .ended))

        let restoredMonitor = AppVolumeMonitorMock()
        let restoredRouter = AppVolumeRouterMock(accessResult: true)
        let restoredPlugin = makePlugin(storage: storage, monitor: restoredMonitor, router: restoredRouter)
        restoredPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 82),
        ]))
        await Task.yield()

        XCTAssertEqual(restoredRouter.accessRequestCount, 0)
        XCTAssertTrue(restoredRouter.lastTargets.isEmpty)
    }

    func testDeactivationStopsMonitorAndRouter() {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock()
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))

        plugin.deactivate(reason: .disabled)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(router.didStop)
        XCTAssertTrue(plugin.primaryPanelState.detail?.controls.isEmpty ?? true)
    }

    func testUnsupportedSystemDisablesPlugin() {
        let router = AppVolumeRouterMock(isSupported: false)
        let plugin = makePlugin(router: router)

        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "需要 macOS 15 或更高版本")
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testCanonicalActionsPublishMuteHalfAndFullVolumeForEachPlayingApp() {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 91),
        ]))

        XCTAssertEqual(
            plugin.actionCatalogEntries.map(\.title),
            ["Music · 0%", "Music · 50%", "Music · 100%"]
        )
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(
            plugin.permissionRequirementIDs(
                for: ActionKey(providerID: "app-volume", actionID: "set-volume")
            ),
            ["system-audio-recording"]
        )
        XCTAssertTrue(
            plugin.permissionRequirementIDs(
                for: ActionKey(providerID: "app-volume", actionID: "unknown")
            ).isEmpty
        )
    }

    func testCanonicalMuteRequestsAccessAndRoutesTheTarget() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 92),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(router.accessRequestCount, 1)
        XCTAssertEqual(router.lastTargets.first?.gain, 0)
    }

    func testCanonicalRouteFailureDoesNotPersistAndReappliesPreviousTargets() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.applyResults = [.failed, .succeeded]
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 94),
        ]))
        let updateCountBeforeAction = router.updates.count
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected routing failure, got \(result)")
        }
        XCTAssertEqual(router.updates.count, updateCountBeforeAction + 2)
        XCTAssertEqual(router.updates[updateCountBeforeAction].first?.gain, 0)
        XCTAssertEqual(router.updates[updateCountBeforeAction + 1].first?.gain, 1)
        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.first?.sliderValue, 1)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 95),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.primaryPanelState.detail?.controls.first?.sliderValue, 1)
    }

    func testCanonicalRouteFailureReportsFailedRollback() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.applyResults = [.failed, .failed]
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 99),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case let .failed(message) = result else {
            return XCTFail("Expected routing failure, got \(result)")
        }
        XCTAssertTrue(message.contains("恢复先前路由失败"))
        XCTAssertEqual(router.updates.count, 3)
    }

    func testCanonicalPersistenceFailureRollsRouteBackAndKeepsPreviousVolume() async throws {
        let storage = AppVolumeStorageMock()
        storage.blockedSetKeys = ["applicationVolumes"]
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 100),
        ]))
        let updateCountBeforeAction = router.updates.count
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case let .failed(message) = result else {
            return XCTFail("expected persistence failure, got \(result)")
        }
        XCTAssertTrue(message.contains("无法保存"))
        XCTAssertEqual(router.updates.count, updateCountBeforeAction + 2)
        XCTAssertEqual(router.updates[updateCountBeforeAction].first?.gain, 0)
        XCTAssertEqual(router.updates[updateCountBeforeAction + 1].first?.gain, 1)
        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.first?.sliderValue, 1)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 101),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.primaryPanelState.detail?.controls.first?.sliderValue, 1)
    }

    func testCanonicalPersistenceFailurePreservesWrongTypedRawValue() async throws {
        let storage = AppVolumeStorageMock()
        storage.setRawValue("sentinel", forKey: "applicationVolumes")
        storage.blockedSetKeys = ["applicationVolumes"]
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 102),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("expected persistence failure, got \(result)")
        }
        XCTAssertEqual(
            storage.rawValue(forKey: "applicationVolumes") as? String,
            "sentinel"
        )
    }

    func testPanelEndAwaitsExistingPermissionRequestWithoutStartingAnother() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.suspendNextAccessRequest = true
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 105),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.5, phase: .changed))
        for _ in 0 ..< 100 where !router.hasSuspendedAccessRequest {
            await Task.yield()
        }
        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.5, phase: .ended))
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(router.accessRequestCount, 1)
        router.completeSuspendedAccessRequest(true)
        for _ in 0 ..< 100 {
            let appliedRequestedGain = router.updates.contains {
                $0.first?.gain == 0.5
            }
            let sliderIsEnabled = plugin.primaryPanelState.detail?.controls.first?.isEnabled == true
            if appliedRequestedGain, sliderIsEnabled {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(router.accessRequestCount, 1)
        XCTAssertTrue(router.updates.contains { $0.first?.gain == 0.5 })
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.first?.isEnabled, true)
    }

    func testCanonicalRouteIgnoresStaleSnapshotUpdateQueuedWhileAwaitingApply() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.suspendNextApply = true
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 96),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let resultTask = Task {
            try await plugin.beginAction(ActionInvocation(
                reference: reference,
                source: .test,
                mode: .background
            )).result()
        }
        for _ in 0 ..< 100 where !router.hasSuspendedApply {
            await Task.yield()
        }
        XCTAssertTrue(router.hasSuspendedApply)

        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 97),
        ]))
        router.completeSuspendedApply(.succeeded)

        let result = try await resultTask.value
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(router.lastTargets.first?.gain, 0)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 98),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.primaryPanelState.detail?.controls.first?.sliderValue, 0)
    }

    func testPanelEditIsDisabledAndIgnoredWhileCanonicalRouteIsSuspended() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.suspendNextApply = true
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 100),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first?.id)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let resultTask = Task {
            try await plugin.beginAction(ActionInvocation(
                reference: reference,
                source: .test,
                mode: .background
            )).result()
        }
        for _ in 0 ..< 100 where !router.hasSuspendedApply {
            await Task.yield()
        }
        XCTAssertTrue(router.hasSuspendedApply)
        XCTAssertFalse(plugin.primaryPanelState.detail?.controls.first?.isEnabled ?? true)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.7, phase: .ended))
        router.completeSuspendedApply(.succeeded)

        let result = try await resultTask.value
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(router.lastTargets.first?.gain, 0)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 101),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.primaryPanelState.detail?.controls.first?.sliderValue, 0)
    }

    func testDeactivationCancelsSuspendedCanonicalRouteWithoutPersisting() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.suspendNextApply = true
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        let context = PluginRuntimeContext(pluginID: "app-volume")
        plugin.activate(context: context)
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 102),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let resultTask = Task {
            try await plugin.beginAction(ActionInvocation(
                reference: reference,
                source: .test,
                mode: .background
            )).result()
        }
        for _ in 0 ..< 100 where !router.hasSuspendedApply {
            await Task.yield()
        }
        XCTAssertTrue(router.hasSuspendedApply)

        plugin.deactivate(reason: .updating)
        router.completeSuspendedApply(.succeeded)

        let result = try await resultTask.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(router.didStop)

        plugin.activate(context: context)
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 103),
        ]))
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: context)
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 104),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.primaryPanelState.detail?.controls.first?.sliderValue, 1)
    }

    @available(macOS 15.0, *)
    func testRouteWorkerRetainsAndRetriesSessionAfterTeardownDeadline() async {
        let session = AppVolumeRouteSessionFake(
            processObjectIDs: [201],
            outputDeviceUID: "output",
            stopResults: [false, true]
        )
        let worker = ApplicationVolumeRouteWorker(
            makeSession: { _, _, _ in session },
            uptime: { 0 },
            sleep: { _ in },
            stopTimeout: 0,
            stopRetryInterval: 0,
            fadeDelay: 0
        )
        let target = ApplicationVolumeTarget(id: "music", processObjectIDs: [201], gain: 0.5)

        let createResult = await worker.applyAndWait(
            targets: [target],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(createResult, .succeeded)
        let firstStopResult = await worker.applyAndWait(
            targets: [],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(firstStopResult, .failed)
        XCTAssertEqual(session.stopCallCount, 1)
        let retryResult = await worker.applyAndWait(
            targets: [],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(retryResult, .succeeded)
        XCTAssertEqual(session.stopCallCount, 2)
    }

    @available(macOS 15.0, *)
    func testRouteWorkerDoesNotReusePartiallyRetiredSessionForRollback() async {
        let oldSession = AppVolumeRouteSessionFake(
            processObjectIDs: [202],
            outputDeviceUID: "output",
            stopResults: [false, false, true]
        )
        let replacement = AppVolumeRouteSessionFake(
            processObjectIDs: [202],
            outputDeviceUID: "output"
        )
        var sessions = [oldSession, replacement]
        let worker = ApplicationVolumeRouteWorker(
            makeSession: { _, _, _ in sessions.removeFirst() },
            uptime: { 0 },
            sleep: { _ in },
            stopTimeout: 0,
            stopRetryInterval: 0,
            fadeDelay: 0
        )
        let oldTarget = ApplicationVolumeTarget(id: "music", processObjectIDs: [202], gain: 0.5)
        let newTarget = ApplicationVolumeTarget(id: "music", processObjectIDs: [203], gain: 0.2)

        let createResult = await worker.applyAndWait(
            targets: [oldTarget],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(createResult, .succeeded)
        let candidateResult = await worker.applyAndWait(
            targets: [newTarget],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(candidateResult, .failed)
        let firstRollback = await worker.applyAndWait(
            targets: [oldTarget],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(firstRollback, .failed)
        XCTAssertEqual(sessions.count, 1)
        let secondRollback = await worker.applyAndWait(
            targets: [oldTarget],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(secondRollback, .succeeded)
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(oldSession.stopCallCount, 3)
    }

    @available(macOS 15.0, *)
    func testRouteWorkerReportsIncompleteStopWithoutOutputDevice() async {
        let session = AppVolumeRouteSessionFake(
            processObjectIDs: [204],
            outputDeviceUID: "output",
            stopResults: [false, true]
        )
        let worker = ApplicationVolumeRouteWorker(
            makeSession: { _, _, _ in session },
            uptime: { 0 },
            sleep: { _ in },
            stopTimeout: 0,
            stopRetryInterval: 0,
            fadeDelay: 0
        )
        let target = ApplicationVolumeTarget(id: "music", processObjectIDs: [204], gain: 0.5)

        let createResult = await worker.applyAndWait(
            targets: [target],
            outputDeviceUID: "output"
        )
        XCTAssertEqual(createResult, .succeeded)
        let firstStopResult = await worker.applyAndWait(targets: [], outputDeviceUID: nil)
        XCTAssertEqual(firstStopResult, .failed)
        let retryResult = await worker.applyAndWait(targets: [], outputDeviceUID: nil)
        XCTAssertEqual(retryResult, .succeeded)
    }

    func testCanonicalActionBecomesUnavailableWhenTheAppStopsPlaying() throws {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 93),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        monitor.send(snapshot(applications: []))

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    private func makePlugin(
        storage: AppVolumeStorageMock? = nil,
        monitor: AppVolumeMonitorMock? = nil,
        router: AppVolumeRouterMock? = nil
    ) -> AppVolumePlugin {
        AppVolumePlugin(
            storage: storage ?? AppVolumeStorageMock(),
            monitor: monitor ?? AppVolumeMonitorMock(),
            router: router ?? AppVolumeRouterMock()
        )
    }

    private func snapshot(applications: [AudioApplication]) -> AudioApplicationSnapshot {
        AudioApplicationSnapshot(
            applications: applications.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            outputDeviceUID: "test-output"
        )
    }

    private func application(id: String, name: String, objectID: AudioObjectID) -> AudioApplication {
        AudioApplication(
            id: id,
            displayName: name,
            bundleIdentifier: id,
            processObjectIDs: [objectID]
        )
    }
}

@MainActor
private final class AppVolumeMonitorMock: AudioApplicationMonitoring {
    var onUpdate: ((AudioApplicationSnapshot) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func refresh() {}

    func stop() {
        isRunning = false
    }

    func send(_ snapshot: AudioApplicationSnapshot) {
        onUpdate?(snapshot)
    }
}

@MainActor
private final class AppVolumeRouterMock: ApplicationVolumeRouting {
    let isSupported: Bool
    let accessResult: Bool
    private(set) var accessRequestCount = 0
    private(set) var updates: [[ApplicationVolumeTarget]] = []
    private(set) var didStop = false
    var applyResults: [ApplicationVolumeRouteResult] = []
    var suspendNextApply = false
    var suspendNextAccessRequest = false
    private var suspendedApplyContinuation:
        CheckedContinuation<ApplicationVolumeRouteResult, Never>?
    private var suspendedAccessContinuation: CheckedContinuation<Bool, Never>?

    var hasSuspendedApply: Bool {
        suspendedApplyContinuation != nil
    }

    var hasSuspendedAccessRequest: Bool {
        suspendedAccessContinuation != nil
    }

    var lastTargets: [ApplicationVolumeTarget] {
        updates.last ?? []
    }

    init(isSupported: Bool = true, accessResult: Bool = true) {
        self.isSupported = isSupported
        self.accessResult = accessResult
    }

    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?) {
        updates.append(targets)
    }

    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult {
        update(targets: targets, outputDeviceUID: outputDeviceUID)
        if suspendNextApply {
            suspendNextApply = false
            return await withCheckedContinuation { continuation in
                suspendedApplyContinuation = continuation
            }
        }
        return applyResults.isEmpty ? .succeeded : applyResults.removeFirst()
    }

    func completeSuspendedApply(_ result: ApplicationVolumeRouteResult) {
        let continuation = suspendedApplyContinuation
        suspendedApplyContinuation = nil
        continuation?.resume(returning: result)
    }

    func requestSystemAudioAccess() async -> Bool {
        accessRequestCount += 1
        if suspendNextAccessRequest {
            suspendNextAccessRequest = false
            return await withCheckedContinuation { continuation in
                suspendedAccessContinuation = continuation
            }
        }
        return accessResult
    }

    func completeSuspendedAccessRequest(_ result: Bool) {
        let continuation = suspendedAccessContinuation
        suspendedAccessContinuation = nil
        continuation?.resume(returning: result)
    }

    func stop() {
        didStop = true
    }
}

@MainActor
private final class AppVolumeStorageMock: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}

    func setRawValue(_ value: Any, forKey key: String) {
        values[key] = value
    }

    func rawValue(forKey key: String) -> Any? {
        values[key]
    }
}

@available(macOS 15.0, *)
private final class AppVolumeRouteSessionFake: ApplicationVolumeRouteSession {
    let processObjectIDs: [AudioObjectID]
    let outputDeviceUID: String
    private(set) var isStopped = false
    private(set) var stopCallCount = 0
    private(set) var gains: [Float] = []
    var stopResults: [Bool]

    init(
        processObjectIDs: [AudioObjectID],
        outputDeviceUID: String,
        stopResults: [Bool] = []
    ) {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.stopResults = stopResults
    }

    func setGain(_ gain: Float) {
        gains.append(gain)
    }

    func stop() -> Bool {
        stopCallCount += 1
        let result = stopResults.isEmpty ? true : stopResults.removeFirst()
        if result { isStopped = true }
        return result
    }
}
