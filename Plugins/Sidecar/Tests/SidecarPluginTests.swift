import XCTest
import Carbon
import MacToolsPluginKit
@testable import SidecarPlugin

@MainActor
final class SidecarPluginTests: XCTestCase {

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
            expandedDetail(for: plugin)?.controls.first?.isEnabled ?? true
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
            expandedDetail(for: plugin)?.controls.first?.isEnabled ?? false
        )
        XCTAssertNil(plugin.rowState.errorMessage)
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

        XCTAssertFalse(plugin.rowState.subtitle.contains("正在"))
        XCTAssertEqual(
            plugin.rowState.errorMessage,
            "Sidecar 请求已提交，但未能确认显示器状态"
        )
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        service.complete(.success(()))
        XCTAssertFalse(plugin.rowState.subtitle.contains("正在"))

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

    func testBackgroundRefreshFindsDisplaysThatAppearAfterPluginStartup() async {
        let service = FakeSidecarService()
        let plugin = makePlugin(
            service: service,
            initialDeviceRefreshDelayNanoseconds: 10_000_000,
            deviceRefreshIntervalNanoseconds: 10_000_000
        )
        let refreshed = expectation(description: "displays refreshed")
        plugin.onStateChange = {
            if plugin.rowState.subtitle == "1 台可连接的 Sidecar 显示器" {
                refreshed.fulfill()
            }
        }
        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.panelItemDidBecomeVisible("control")

        service.updateDevices([
            SidecarDevice(id: "vision-pro", name: "Apple Vision Pro", connectionState: .disconnected)
        ])

        await fulfillment(of: [refreshed], timeout: 1)
    }

    func testConnectingAnotherDisplaySwitchesAfterTheCurrentDisplayDisconnects() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        XCTAssertEqual(
            expandedDetail(for: plugin)?.primaryControls.last?.actionTitle,
            "Target iPad · 切换"
        )
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current"])
        XCTAssertEqual(plugin.rowState.subtitle, "正在断开 Current iPad，然后连接 Target iPad…")

        service.complete(.success(()))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current", "connect:ipad-target"])
        service.complete(.success(()))
        XCTAssertEqual(
            expandedDetail(for: plugin)?.primaryControls.last?.actionTitle,
            "已断开 Current iPad，并已提交连接 Target iPad 的请求"
        )
        XCTAssertNil(plugin.rowState.errorMessage)
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
        XCTAssertEqual(plugin.rowState.errorMessage, "无法断开 Current iPad，因此无法切换到 Target iPad")
        XCTAssertEqual(plugin.rowState.subtitle, "1 台已连接 · 1 台可连接")
    }

    func testWiredOnlyPreferenceChangesDirectConnectActionAndRequest() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateTransport(.wiredOnly, for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)

        XCTAssertEqual(expandedDetail(for: plugin)?.primaryControls.first?.actionTitle, "My iPad · 仅通过有线连接")
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertTrue(service.didConnect)
        XCTAssertTrue(service.receivedWiredOnly)
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
        plugin.panelItemDidBecomeVisible("control")

        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testServiceErrorsAndUnsupportedStateAreShown() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = makePlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.deviceUnavailable))
        XCTAssertEqual(plugin.rowState.errorMessage, "Sidecar 显示器已不在可用设备列表中")

        let unsupported = makePlugin(service: FakeSidecarService(availability: .unsupported(.frameworkLoadFailed)))
        XCTAssertEqual(unsupported.rowState.errorMessage, "此系统无法加载 SidecarCore")
    }

    private func expandedDetail(for plugin: SidecarPlugin) -> PluginPanelDetail? {
        plugin.handleAction(.setDisclosureExpanded(true))
        return plugin.rowState.detail
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
