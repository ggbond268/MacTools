import XCTest
import Carbon
import MacToolsPluginKit
@testable import SidecarPlugin

@MainActor
final class SidecarPluginTests: XCTestCase {
    func testCommonApplicationShortcutBindingsRequireConflictWarning() {
        XCTAssertTrue(
            CommonApplicationShortcutBindings.requiresConflictWarning(
                for: ShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
            )
        )
        XCTAssertTrue(
            CommonApplicationShortcutBindings.requiresConflictWarning(
                for: ShortcutBinding(keyCode: UInt16(kVK_ANSI_F), modifiers: .command)
            )
        )
        XCTAssertFalse(
            CommonApplicationShortcutBindings.requiresConflictWarning(
                for: ShortcutBinding(
                    keyCode: UInt16(kVK_ANSI_1),
                    modifiers: [.command, .option]
                )
            )
        )
    }

    func testPublishesGlobalAndPerDeviceCanonicalActions() throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(service: service)
        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))

        XCTAssertEqual(plugin.actionDefinitions.count, 3)
        XCTAssertTrue(plugin.actionDefinitions.contains {
            $0.key.actionID == "connect-first-available"
        })
        XCTAssertTrue(plugin.actionDefinitions.contains {
            $0.key.actionID == "disconnect-all"
        })
        XCTAssertTrue(plugin.actionDefinitions.allSatisfy {
            $0.capabilities.contains(.changesDisplayConfiguration)
        })
        XCTAssertTrue(plugin.actionDefinitions.allSatisfy {
            $0.externalInvocationPolicy == .confirmAlways
                && $0.confirmation != nil
                && $0.risk == .safe
        })
        let deviceAction = try XCTUnwrap(plugin.actionDefinitions.first {
            $0.title.contains("My iPad")
        })
        XCTAssertEqual(plugin.actionAvailability(for: ActionReference(key: deviceAction.key)), .available)

        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(
                key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
            )),
            .requiresPluginPreferences
        )
        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(key: deviceAction.key)),
            .requiresPluginPreferences
        )
        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(
                key: ActionKey(providerID: "sidecar", actionID: "device.missing")
            )),
            .excluded
        )
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        XCTAssertEqual(
            plugin.actionReferences(inPortablePreferences: backup),
            [
                ActionReference(
                    key: ActionKey(
                        providerID: "sidecar",
                        actionID: "connect-first-available"
                    )
                ),
                ActionReference(key: deviceAction.key),
            ]
        )
    }

    func testCanonicalConnectActionWaitsForCallbackAndConfirmedTopology() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(service: service)
        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let resultTask = Task { await handle.result() }
        for _ in 0 ..< 20 where service.operations.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(service.operations, ["connect:ipad-1"])
        service.complete(.success(()))
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        plugin.refresh()
        let result = await resultTask.value
        XCTAssertEqual(result, .succeeded())
    }

    func testCanonicalDisconnectAllWaitsForConfirmedTopology() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        let plugin = makePlugin(service: service)
        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "disconnect-all")
        )
        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let resultTask = Task { await handle.result() }
        for _ in 0 ..< 20 where service.operations.isEmpty {
            await Task.yield()
        }

        service.complete(.success(()))
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        plugin.refresh()

        let result = await resultTask.value
        XCTAssertEqual(result, .succeeded())
    }

    func testTimedOutCanonicalActionStaysBlockedUntilLateCallbackReconciles() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(service: service, operationTimeoutNanoseconds: 1_000_000)
        plugin.activate(context: PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        ))
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertFalse(
            plugin.primaryPanelState.detail?.controls.first?.isEnabled ?? true
        )

        service.complete(.success(()))

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        plugin.refresh()

        let disconnectReference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "disconnect-all")
        )
        XCTAssertTrue(plugin.actionAvailability(for: disconnectReference).isAvailable)
        XCTAssertTrue(
            plugin.primaryPanelState.detail?.controls.first?.isEnabled ?? false
        )
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testTimedOutConnectUnblocksWhenSnapshotConfirmsTopology() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(service: service, operationTimeoutNanoseconds: 1_000_000)
        plugin.activate(context: PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        ))
        let connectReference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: connectReference,
            source: .actionGrid,
            mode: .foreground
        )).result()
        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }

        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        plugin.refresh()
        let disconnectReference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "disconnect-all")
        )

        XCTAssertTrue(plugin.actionAvailability(for: disconnectReference).isAvailable)
        XCTAssertTrue(plugin.primaryPanelState.detail?.controls.first?.isEnabled ?? false)
    }

    func testTimedOutDisconnectAllUnblocksWhenSnapshotConfirmsTopology() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        let plugin = makePlugin(service: service, operationTimeoutNanoseconds: 1_000_000)
        plugin.activate(context: PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        ))
        let disconnectReference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "disconnect-all")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: disconnectReference,
            source: .actionGrid,
            mode: .foreground
        )).result()
        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }

        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        plugin.refresh()
        let connectReference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        XCTAssertTrue(plugin.actionAvailability(for: connectReference).isAvailable)
        XCTAssertTrue(plugin.primaryPanelState.detail?.controls.first?.isEnabled ?? false)
    }

    func testTimedOutCanonicalActionStaysBlockedAcrossReactivation() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(service: service, operationTimeoutNanoseconds: 1_000_000)
        let context = PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        )
        plugin.activate(context: context)
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        )).result()
        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }

        plugin.deactivate(reason: .updating)
        plugin.activate(context: context)
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        service.complete(.success(()))
        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        plugin.refresh()
        let disconnectReference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "disconnect-all")
        )
        XCTAssertTrue(plugin.actionAvailability(for: disconnectReference).isAvailable)
    }

    func testDeactivationRecoveryTerminalizesPendingOperationAndAllowsRetry() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(
            service: service,
            operationTimeoutNanoseconds: 1_000_000_000,
            operationRecoveryNanoseconds: 1_000_000
        )
        let context = PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )
        plugin.activate(context: context)
        let firstHandle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let firstResult = Task { await firstHandle.result() }
        for _ in 0 ..< 20 where service.operations.isEmpty {
            await Task.yield()
        }

        plugin.deactivate(reason: .updating)
        let completedFirstResult = await firstResult.value
        XCTAssertEqual(completedFirstResult, .cancelled)
        try await Task.sleep(nanoseconds: 10_000_000)
        plugin.activate(context: context)

        XCTAssertFalse(plugin.primaryPanelState.subtitle.contains("正在"))
        XCTAssertEqual(
            plugin.primaryPanelState.errorMessage,
            "Sidecar 请求已提交，但未能确认显示器状态"
        )
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        service.complete(.success(()))
        XCTAssertFalse(plugin.primaryPanelState.subtitle.contains("正在"))

        let retryHandle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let retryResult = Task { await retryHandle.result() }
        for _ in 0 ..< 20 where service.operations.count < 2 {
            await Task.yield()
        }
        service.complete(.success(()))
        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        plugin.refresh()

        let completedRetryResult = await retryResult.value
        XCTAssertEqual(completedRetryResult, .succeeded())
    }

    func testTimedOutCanonicalActionRecoversWhenSidecarCoreNeverCallsBack() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let plugin = makePlugin(
            service: service,
            operationTimeoutNanoseconds: 1_000_000,
            operationRecoveryNanoseconds: 1_000_000
        )
        plugin.activate(context: PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        ))
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        )).result()
        guard case .failed = result else {
            return XCTFail("Expected timeout failure, got \(result)")
        }

        for _ in 0 ..< 100 where !plugin.actionAvailability(for: reference).isAvailable {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertTrue(plugin.primaryPanelState.detail?.controls.first?.isEnabled ?? false)
    }

    func testConnectPreparesPresentationBeforeCallingSidecarCore() async throws {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        var didPrepare = false
        service.onOperation = {
            XCTAssertTrue(didPrepare)
        }
        let plugin = makePlugin(
            service: service,
            presentationPreparation: { didPrepare = true }
        )
        plugin.activate(context: PluginRuntimeContext(
            pluginID: "sidecar",
            storage: InMemoryPluginStorage()
        ))
        let reference = ActionReference(
            key: ActionKey(providerID: "sidecar", actionID: "connect-first-available")
        )

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let resultTask = Task { await handle.result() }
        for _ in 0 ..< 20 where service.operations.isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(didPrepare)
        service.complete(.success(()))
        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected),
        ])
        plugin.refresh()
        _ = await resultTask.value
    }

    func testPublishedActionSymbolsAreAvailable() {
        let plugin = makePlugin(service: FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ]))

        for definition in plugin.actionDefinitions {
            XCTAssertTrue(
                PluginSystemImage.isAvailable(definition.systemImage),
                "Unavailable Sidecar action symbol: \(definition.systemImage)"
            )
        }
    }

    func testLegacySidecarShortcutsMigrateToCanonicalActionReferences() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        let connectBinding = ShortcutBinding(keyCode: 0, modifiers: [.command])
        let deviceBinding = ShortcutBinding(keyCode: 1, modifiers: [.command])
        store.updateConnectFirstAvailableShortcut(connectBinding)
        store.updateShortcut(deviceBinding, for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)
        var persistentPreferenceNotifications = 0
        plugin.onPersistentPreferencesChange = {
            persistentPreferenceNotifications += 1
        }
        plugin.shortcutBindingResolver = { definitionID in
            switch definitionID {
            case "connect-first-available": connectBinding
            case "device.ipad-1": deviceBinding
            default: nil
            }
        }

        let assignments = plugin.legacyActionShortcutAssignments

        XCTAssertEqual(assignments.count, 2)
        XCTAssertTrue(assignments.contains {
            $0.reference.key.actionID == "connect-first-available"
                && $0.binding == connectBinding
        })
        XCTAssertTrue(assignments.contains {
            $0.reference.key.actionID.hasPrefix("device.")
                && $0.binding == deviceBinding
        })

        plugin.legacyActionShortcutsDidMigrate()
        XCTAssertNil(store.connectFirstAvailableShortcut)
        XCTAssertNil(store.preference(for: "ipad-1")?.shortcut)
        XCTAssertEqual(persistentPreferenceNotifications, 1)
    }

    func testSidecarDeviceIdentifierAcceptsUUIDAndStringValues() {
        let uuid = UUID(uuidString: "9DFBEA6D-4DCF-431D-B7A0-A74F26231DAF")!

        XCTAssertEqual(
            SidecarCoreService.identifierString(from: uuid as NSUUID),
            "9DFBEA6D-4DCF-431D-B7A0-A74F26231DAF"
        )
        XCTAssertEqual(SidecarCoreService.identifierString(from: "sidecar-display" as NSString), "sidecar-display")
    }

    func testSidecarDeviceIdentifierRejectsUnstableObjectDescriptions() {
        XCTAssertNil(SidecarCoreService.identifierString(from: NSObject()))
    }

    func testCollapsedRowSaysWhenNoSidecarDisplayIsAvailable() {
        let plugin = makePlugin(service: FakeSidecarService())

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "未发现可连接的 Sidecar 显示器")
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testBackgroundRefreshFindsDisplaysThatAppearAfterPluginStartup() async {
        let service = FakeSidecarService()
        let plugin = makePlugin(
            service: service,
            initialDeviceRefreshDelayNanoseconds: 10_000_000,
            deviceRefreshIntervalNanoseconds: 10_000_000
        )
        let refreshed = expectation(description: "displays refreshed")
        plugin.onStateChange = {
            if plugin.primaryPanelState.subtitle == "1 台可连接的 Sidecar 显示器" {
                refreshed.fulfill()
            }
        }
        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.panelSurfaceDidBecomeVisible(.primary)

        service.updateDevices([
            SidecarDevice(id: "vision-pro", name: "Apple Vision Pro", connectionState: .disconnected)
        ])

        await fulfillment(of: [refreshed], timeout: 1)
    }

    func testPollingRunsOnlyWhileThePrimaryPanelIsVisible() async {
        let service = FakeSidecarService()
        let plugin = makePlugin(
            service: service,
            initialDeviceRefreshDelayNanoseconds: 10_000_000,
            deviceRefreshIntervalNanoseconds: 10_000_000
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        let callsWhileHidden = service.reachableDevicesCallCount
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(service.reachableDevicesCallCount, callsWhileHidden)

        plugin.panelSurfaceDidBecomeVisible(.primary)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertGreaterThan(service.reachableDevicesCallCount, callsWhileHidden)

        plugin.panelSurfaceDidBecomeHidden(.primary)
        let callsAfterHiding = service.reachableDevicesCallCount
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(service.reachableDevicesCallCount, callsAfterHiding)
    }

    func testConnectedDevicesAppearFirstWithGreenConnectedIconAndDisconnectAction() {
        let plugin = makePlugin(service: FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-available", name: "Available iPad", connectionState: .disconnected),
            SidecarDevice(id: "ipad-connected", name: "Connected iPad", connectionState: .connected)
        ]))

        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台已连接 · 1 台可连接")
        XCTAssertEqual(controls.map(\.id), ["sidecar-disconnect.ipad-connected", "sidecar-connect.ipad-available"])
        XCTAssertEqual(controls[0].sectionTitle, "已连接")
        XCTAssertEqual(controls[0].actionTitle, "Connected iPad · 断开连接")
        XCTAssertEqual(controls[0].actionIconSystemName, "checkmark.circle.fill")
        XCTAssertEqual(controls[1].sectionTitle, "可用的 Sidecar 显示器")
        XCTAssertFalse(controls.contains(where: \.showsLeadingDivider))
    }

    func testConnectingAnotherDisplaySwitchesAfterTheCurrentDisplayDisconnects() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.last?.actionTitle,
            "Target iPad · 切换"
        )
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在断开 Current iPad，然后连接 Target iPad…")

        service.complete(.success(()))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current", "connect:ipad-target"])
        service.complete(.success(()))
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.last?.actionTitle,
            "已断开 Current iPad，并已提交连接 Target iPad 的请求"
        )
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchDoesNotConnectTheTargetWhenDisconnectingTheCurrentDisplayFails() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))
        service.complete(.failure(.system("Disconnect failed")))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current"])
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法断开 Current iPad，因此无法切换到 Target iPad")
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台已连接 · 1 台可连接")
    }

    func testSwitchExplainsThatThePreviousDisplayWasDisconnectedWhenTargetConnectionFails() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))
        service.complete(.success(()))
        service.complete(.failure(.system("Target unavailable")))

        XCTAssertEqual(
            plugin.primaryPanelState.errorMessage,
            "已断开 Current iPad，但无法连接 Target iPad：Target unavailable"
        )
    }

    func testWiredOnlyPreferenceChangesDirectConnectActionAndRequest() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateTransport(.wiredOnly, for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)

        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.first?.actionTitle, "My iPad · 仅通过有线连接")
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertTrue(service.didConnect)
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testUnknownConnectionStateDoesNotClaimConnectOrDisconnect() {
        let plugin = makePlugin(service: FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .unknown)
        ]))

        let control = plugin.primaryPanelState.detail?.primaryControls.first
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台 Sidecar 显示器的连接状态不可用")
        XCTAssertEqual(control?.actionIconSystemName, "questionmark.circle")
        XCTAssertFalse(control?.isEnabled ?? true)
    }

    func testPendingThenSuccessReturnsRowToLiveSummary() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在连接 My iPad…")
        service.complete(.success(()))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台可连接的 Sidecar 显示器")
        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.first?.actionIconSystemName, "checkmark.circle")
    }

    func testMissingWiredCapabilityKeepsAutomaticConnectionAvailable() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        service.supportsWiredOnlyConnections = false
        let plugin = makePlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertTrue(service.didConnect)
        XCTAssertFalse(service.receivedWiredOnly)
    }

    func testShortcutPreferencesPersistWhenDeviceIsUnavailable() {
        let storage = InMemoryPluginStorage()
        let store = SidecarPreferencesStore(storage: storage)
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.reconcile(with: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        store.updateTransport(.wiredOnly, for: "ipad-1")
        store.updateShortcutAction(.connect, for: "ipad-1")
        store.updateShortcut(binding, for: "ipad-1")

        let reloaded = SidecarPreferencesStore(storage: storage)
        XCTAssertEqual(reloaded.devices, [
            SidecarDevicePreference(
                id: "ipad-1",
                name: "My iPad",
                transport: .wiredOnly,
                shortcutAction: .connect,
                shortcut: binding
            )
        ])
        reloaded.reconcile(with: [])
        XCTAssertEqual(reloaded.devices.count, 1)
    }

    func testPortablePreferencesPreservePriorityAndGlobalShortcuts() {
        let source = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        source.reconcile(with: [
            SidecarDevice(id: "ipad-1", name: "First"),
            SidecarDevice(id: "ipad-2", name: "Second")
        ])
        source.move(deviceID: "ipad-2", before: "ipad-1")
        source.updateTransport(.wiredOnly, for: "ipad-2")
        source.updateConnectFirstAvailableShortcut(
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        )
        source.updateDisconnectAllShortcut(
            ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        )

        let restored = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        restored.restorePortablePreferences(from: try! XCTUnwrap(source.portablePreferencesData()))

        XCTAssertEqual(restored.devices.map(\.id), ["ipad-2", "ipad-1"])
        XCTAssertEqual(restored.preference(for: "ipad-2")?.transport, .wiredOnly)
        XCTAssertEqual(
            restored.connectFirstAvailableShortcut,
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        )
        XCTAssertEqual(
            restored.disconnectAllShortcut,
            ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            restored.deviceIDs(inPortablePreferences: try! XCTUnwrap(source.portablePreferencesData())),
            ["ipad-2", "ipad-1"]
        )
        XCTAssertNil(restored.deviceIDs(inPortablePreferences: Data("invalid".utf8)))
    }

    func testPortablePreferencesWriteFailureRollsBackAllKeys() throws {
        let source = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        source.reconcile(with: [SidecarDevice(id: "new-ipad", name: "New iPad")])
        source.updateDisconnectAllShortcut(
            ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )
        source.updateConnectFirstAvailableShortcut(
            ShortcutBinding(keyCode: 3, modifiers: [.command, .shift])
        )
        let backup = try XCTUnwrap(source.portablePreferencesData())

        let storage = InMemoryPluginStorage()
        let destination = SidecarPreferencesStore(storage: storage)
        destination.reconcile(with: [SidecarDevice(id: "old-ipad", name: "Old iPad")])
        let oldDisconnect = ShortcutBinding(keyCode: 4, modifiers: [.command, .option])
        destination.updateDisconnectAllShortcut(oldDisconnect)
        storage.blockedSetKeys = ["disconnectAllShortcut"]

        XCTAssertFalse(destination.restorePortablePreferences(from: backup))
        storage.blockedSetKeys = []
        let reloaded = SidecarPreferencesStore(storage: storage)
        XCTAssertEqual(reloaded.devices.map(\.id), ["old-ipad"])
        XCTAssertEqual(reloaded.disconnectAllShortcut, oldDisconnect)
        XCTAssertNil(reloaded.connectFirstAvailableShortcut)
    }

    func testFailedMutationAndIdenticalRestoreDoNotEmitPersistentPreferenceSignal() throws {
        let storage = InMemoryPluginStorage()
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
        ])
        let preferences = SidecarPreferencesStore(storage: storage)
        XCTAssertTrue(preferences.reconcile(with: service.reachableDevices()))
        let plugin = makePlugin(service: service, preferences: preferences)
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        var notifications = 0
        plugin.onPersistentPreferencesChange = { notifications += 1 }
        notifications = 0

        storage.blockedSetKeys = ["savedDevices"]
        plugin.shortcutBindingDidChange(
            id: "device.ipad-1",
            binding: ShortcutBinding(keyCode: 0, modifiers: [.command])
        )
        storage.blockedSetKeys = []
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))

        XCTAssertFalse(preferences.preference(for: "ipad-1")?.hasShortcutConfiguration == true)
        XCTAssertEqual(notifications, 0)
    }

    func testPortablePreferencesRejectWrongTypedRawDeviceValueWithoutRemovingIt() throws {
        let source = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        source.reconcile(with: [SidecarDevice(id: "new-ipad", name: "New iPad")])
        let backup = try XCTUnwrap(source.portablePreferencesData())
        let storage = InMemoryPluginStorage()
        storage.setRawValue("sentinel", forKey: "savedDevices")
        let destination = SidecarPreferencesStore(storage: storage)

        XCTAssertFalse(destination.restorePortablePreferences(from: backup))
        XCTAssertEqual(storage.rawValue(forKey: "savedDevices") as? String, "sentinel")
    }

    func testOnlyCustomizedOfflineDevicePreferencesNeedToRemainVisible() {
        let defaultPreference = SidecarDevicePreference(id: "ipad-1", name: "My iPad")
        let wiredPreference = SidecarDevicePreference(
            id: "ipad-2",
            name: "Desk iPad",
            transport: .wiredOnly
        )
        let shortcutPreference = SidecarDevicePreference(
            id: "ipad-3",
            name: "Travel iPad",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        )

        XCTAssertFalse(defaultPreference.hasCustomConfiguration)
        XCTAssertTrue(wiredPreference.hasCustomConfiguration)
        XCTAssertTrue(shortcutPreference.hasCustomConfiguration)
    }

    func testConfiguredPerDeviceShortcutUsesHostActionAndSavedTransport() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateTransport(.wiredOnly, for: "ipad-1")
        store.updateShortcutAction(.connect, for: "ipad-1")
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.updateShortcut(binding, for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)

        XCTAssertEqual(
            plugin.shortcutDefinitions.first(where: { $0.id == "device.ipad-1" })?.defaultBinding,
            binding
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.handleShortcutAction(id: "device.ipad-1")
        XCTAssertTrue(service.didConnect)
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testConnectFirstAvailableShortcutUsesSavedPriorityAndConnectionMode() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "First", connectionState: .disconnected),
            SidecarDevice(id: "ipad-2", name: "Second", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.move(deviceID: "ipad-2", before: "ipad-1")
        store.updateTransport(.wiredOnly, for: "ipad-2")
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.updateConnectFirstAvailableShortcut(binding)
        let plugin = makePlugin(service: service, preferences: store)

        XCTAssertEqual(
            plugin.shortcutDefinitions.first(where: { $0.id == "connect-first-available" })?.defaultBinding,
            binding
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.handleShortcutAction(id: "connect-first-available")

        XCTAssertEqual(service.connectedDeviceID, "ipad-2")
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testConnectFirstAvailableDoesNotDisconnectAnExistingDisplay() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateConnectFirstAvailableShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]))
        let plugin = makePlugin(service: service, preferences: store)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.handleShortcutAction(id: "connect-first-available")

        withExtendedLifetime(plugin) {}
        XCTAssertTrue(service.operations.isEmpty)
    }

    func testDisconnectShortcutDoesNotGuessUnknownOrDisconnectedState() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcutAction(.disconnect, for: "ipad-1")
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))

        plugin.handleShortcutAction(id: "device.ipad-1")

        XCTAssertFalse(service.didDisconnect)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "该 Sidecar 显示器当前未连接")
    }

    func testDeactivationStopsPolling() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))

        plugin.deactivate(reason: .disabled)
        plugin.refresh()
        plugin.panelSurfaceDidBecomeVisible(.primary)

        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testFailedOperationFeedbackRemainsVisible() async {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service, operationFeedbackNanoseconds: 1)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.system("Unavailable")))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Unavailable")
    }

    func testClosingThePanelClearsTerminalFeedbackThatWasAlreadyVisible() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.panelSurfaceDidBecomeVisible(.primary)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.system("Unavailable")))

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Unavailable")
        plugin.panelSurfaceDidBecomeHidden(.primary)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testServiceErrorsAndUnsupportedStateAreShown() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = makePlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.deviceUnavailable))
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Sidecar 显示器已不在可用设备列表中")

        let unsupported = makePlugin(service: FakeSidecarService(availability: .unsupported(.frameworkLoadFailed)))
        XCTAssertEqual(unsupported.primaryPanelState.errorMessage, "此系统无法加载 SidecarCore")
    }

    private func makePlugin(
        service: FakeSidecarService,
        preferences: SidecarPreferencesStore? = nil,
        operationTimeoutNanoseconds: UInt64 = 15_000_000_000,
        operationFeedbackNanoseconds: UInt64 = 4_000_000_000,
        operationRecoveryNanoseconds: UInt64 = 5_000_000_000,
        terminalFeedbackExpiration: TimeInterval = 30,
        initialDeviceRefreshDelayNanoseconds: UInt64 = 750_000_000,
        deviceRefreshIntervalNanoseconds: UInt64 = 5_000_000_000,
        presentationPreparation: @escaping @MainActor @Sendable () -> Void = {}
    ) -> SidecarPlugin {
        SidecarPlugin(
            service: service,
            preferences: preferences ?? SidecarPreferencesStore(storage: InMemoryPluginStorage()),
            operationTimeoutNanoseconds: operationTimeoutNanoseconds,
            operationFeedbackNanoseconds: operationFeedbackNanoseconds,
            operationRecoveryNanoseconds: operationRecoveryNanoseconds,
            terminalFeedbackExpiration: terminalFeedbackExpiration,
            initialDeviceRefreshDelayNanoseconds: initialDeviceRefreshDelayNanoseconds,
            deviceRefreshIntervalNanoseconds: deviceRefreshIntervalNanoseconds,
            presentationPreparation: presentationPreparation
        )
    }
}

@MainActor
private final class FakeSidecarService: SidecarServicing {
    var availability: SidecarServiceAvailability = .available
    var isMinimumTestedSystem = true
    var supportsWiredOnlyConnections = true
    var onDevicesChanged: (() -> Void)?
    private var pendingCompletion: ((Result<Void, SidecarServiceError>) -> Void)?
    private(set) var didConnect = false
    private(set) var didDisconnect = false
    private(set) var receivedWiredOnly = false
    private(set) var connectedDeviceID: String?
    private(set) var operations: [String] = []
    private(set) var reachableDevicesCallCount = 0
    var onOperation: (() -> Void)?
    private var devices: [SidecarDevice]

    init(devices: [SidecarDevice] = [], availability: SidecarServiceAvailability = .available) {
        self.devices = devices
        self.availability = availability
    }

    func reachableDevices() -> [SidecarDevice] {
        reachableDevicesCallCount += 1
        return devices
    }
    func updateDevices(_ devices: [SidecarDevice]) { self.devices = devices }

    func connect(to device: SidecarDevice, wiredOnly: Bool, completion: @escaping (Result<Void, SidecarServiceError>) -> Void) {
        onOperation?()
        didConnect = true
        receivedWiredOnly = wiredOnly
        connectedDeviceID = device.id
        operations.append("connect:\(device.id)")
        pendingCompletion = completion
    }

    func disconnect(from device: SidecarDevice, completion: @escaping (Result<Void, SidecarServiceError>) -> Void) {
        onOperation?()
        didDisconnect = true
        operations.append("disconnect:\(device.id)")
        pendingCompletion = completion
    }

    func complete(_ result: Result<Void, SidecarServiceError>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}

@MainActor
private final class InMemoryPluginStorage: PluginStorage {
    private var store: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { store[key] }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func string(forKey key: String) -> String? { store[key] as? String }
    func stringArray(forKey key: String) -> [String]? { store[key] as? [String] }
    func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        store[key] = value
    }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard store[key] == nil, let value = store[legacyKey] else { return }
        store[key] = value
        store.removeValue(forKey: legacyKey)
    }

    func setRawValue(_ value: Any, forKey key: String) {
        store[key] = value
    }

    func rawValue(forKey key: String) -> Any? {
        store[key]
    }
}
