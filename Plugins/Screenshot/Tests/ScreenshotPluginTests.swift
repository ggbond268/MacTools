import Foundation
import MacToolsPluginKit
import XCTest

@testable import ScreenshotPlugin

@MainActor
final class ScreenshotPluginTests: XCTestCase {
    func testHostPanelActionsShortcutsAndPermissionContracts() {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.metadata.id, "screenshot")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
        XCTAssertNotNil(plugin.settingsPage)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["screen-recording"])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["capture", "quick-capture"])
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["capture", "quick-capture"])
        for definition in plugin.actionDefinitions {
            XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
            XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
            XCTAssertEqual(plugin.permissionRequirementIDs(for: definition.key), ["screen-recording"])
        }
        XCTAssertTrue(plugin.shortcutDefinitions.allSatisfy { $0.defaultBinding == nil && !$0.isRequired })
    }

    func testPanelAndShortcutsDispatchCaptureModesAndIgnoreUnknownControls() {
        var modes: [Bool] = []
        let plugin = makePlugin(capture: { modes.append($0) })
        plugin.handleAction(.invokeAction(controlID: "unknown"))
        plugin.handleAction(.setSwitch(true))
        plugin.handleShortcutAction(id: "unknown")
        XCTAssertTrue(modes.isEmpty)
        plugin.handleAction(.invokeAction(controlID: "execute"))
        plugin.handleShortcutAction(id: "capture")
        plugin.handleShortcutAction(id: "quick-capture")
        XCTAssertEqual(modes, [false, false, true])
    }

    func testDeniedPermissionRequestsHostGuidanceWithoutCapturing() {
        var count = 0
        var requested: [String] = []
        let plugin = makePlugin(screenAccess: { false }, capture: { _ in count += 1 })
        plugin.requestPermissionGuidance = { requested.append($0) }
        plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(requested, ["screen-recording"])
        XCTAssertFalse(plugin.permissionState(for: "screen-recording").isGranted)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        XCTAssertFalse(plugin.actionAvailability(for: reference()).isAvailable)
    }

    func testPermissionIsRecheckedOnEveryCaptureAndRefreshClearsPermissionError() {
        var granted = true
        var count = 0
        let plugin = makePlugin(screenAccess: { granted }, capture: { _ in count += 1 })
        granted = false
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        granted = true
        plugin.refresh()
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
        XCTAssertTrue(plugin.permissionState(for: "screen-recording").isGranted)
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 1)
    }

    func testPermissionActionOnlyRequestsKnownPermissionAndRefreshesState() {
        var granted = false
        var requests = 0
        let plugin = makePlugin(screenAccess: { granted }, requestScreenAccess: {
            requests += 1
            granted = true
        })
        plugin.handlePermissionAction(id: "unknown")
        XCTAssertEqual(requests, 0)
        plugin.handlePermissionAction(id: "screen-recording")
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(plugin.permissionState(for: "screen-recording").isGranted)
    }

    func testCanonicalActionRunsOnlyWhenHandleIsExecuted() async throws {
        var modes: [Bool] = []
        let plugin = makePlugin(capture: { modes.append($0) })
        let handle = try plugin.beginAction(invocation(actionID: "quick-capture"))
        XCTAssertTrue(modes.isEmpty)
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(modes, [true])
    }

    func testCancelledHandleCannotLaunchCapture() async throws {
        var count = 0
        let plugin = makePlugin(capture: { _ in count += 1 })
        let handle = try plugin.beginAction(invocation())
        handle.cancel()
        let result = await handle.result()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(count, 0)
    }

    func testBackgroundAndAutomaticActionsCannotCapture() async throws {
        var count = 0
        let plugin = makePlugin(capture: { _ in count += 1 })
        for request in [invocation(mode: .background), invocation(source: .automaticRule)] {
            let result = await (try plugin.beginAction(request)).result()
            guard case .failed = result else { return XCTFail("Expected foreground-only rejection") }
        }
        XCTAssertEqual(count, 0)
    }

    func testUnknownProviderActionAndSchemaAreUnavailable() async throws {
        let plugin = makePlugin()
        for value in [
            ActionReference(key: ActionKey(providerID: "other", actionID: "capture")),
            reference(actionID: "unknown"),
            ActionReference(key: reference().key, schemaVersion: 2),
        ] {
            XCTAssertFalse(plugin.actionAvailability(for: value).isAvailable)
            let result = await (try plugin.beginAction(ActionInvocation(reference: value, source: .test, mode: .foreground))).result()
            guard case .failed = result else { return XCTFail("Expected unknown action rejection") }
        }
        XCTAssertEqual(plugin.permissionRequirementIDs(for: ActionKey(providerID: "other", actionID: "capture")), [])
    }

    func testDeactivationRejectsPendingAndNewActionsUntilReactivated() async throws {
        var count = 0
        let plugin = makePlugin(capture: { _ in count += 1 })
        let pending = try plugin.beginAction(invocation())
        plugin.deactivate(reason: .updating)
        let result = await pending.result()
        guard case .failed = result else { return XCTFail("Pending action must not reopen a disabled plugin") }
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 0)
        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
        plugin.activate(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 1)
    }

    func testFolderSettingsPersistInPluginStorageAndCancelledPickerPreservesValue() {
        let storage = ScreenshotTestStorage()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotPluginTests", isDirectory: true)
        var selection: URL? = folder
        var picked = 0
        let plugin = makePlugin(storage: storage, folderPicker: { _ in
            picked += 1
            return selection
        })
        plugin.handleSettingsAction(.invoke(controlID: "unknown"))
        XCTAssertEqual(picked, 0)
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage))
        XCTAssertEqual(environment.saveFolder, folder)
        selection = nil
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        XCTAssertEqual(environment.saveFolder, folder)
        selection = URL(string: "https://example.com/")
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        XCTAssertEqual(environment.saveFolder, folder)
        plugin.deactivate(reason: .disabled)
        let countBeforeDeactivation = picked
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        XCTAssertEqual(picked, countBeforeDeactivation)
    }

    private func makePlugin(
        storage: PluginStorage? = nil,
        screenAccess: @escaping @MainActor () -> Bool = { true },
        requestScreenAccess: @escaping @MainActor () -> Void = {},
        capture: @escaping @MainActor (Bool) -> Void = { _ in },
        folderPicker: @escaping @MainActor (URL) -> URL? = { _ in nil }
    ) -> ScreenshotPlugin {
        ScreenshotPlugin(
            context: PluginRuntimeContext(pluginID: "screenshot", storage: storage ?? ScreenshotTestStorage()),
            screenAccess: screenAccess,
            requestScreenAccess: requestScreenAccess,
            capture: capture,
            folderPicker: folderPicker
        )
    }

    private func reference(actionID: String = "capture") -> ActionReference {
        ActionReference(key: ActionKey(providerID: "screenshot", actionID: actionID))
    }

    private func invocation(
        actionID: String = "capture",
        source: ActionExecutionSource = .test,
        mode: ActionExecutionMode = .foreground
    ) -> ActionInvocation {
        ActionInvocation(reference: reference(actionID: actionID), source: source, mode: mode)
    }
}

@MainActor
final class ScreenshotTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
