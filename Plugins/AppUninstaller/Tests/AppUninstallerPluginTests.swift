import Foundation
import XCTest
import MacToolsPluginKit
@testable import AppUninstallerPlugin

@MainActor
final class AppUninstallerPluginTests: XCTestCase {
    func testPermissionStartsUnconfirmedAndUsesAsynchronousProbe() async throws {
        let controller = makeController()
        let plugin = AppUninstallerPlugin(controller: controller, localization: .init(bundle: .main),
                                           permissionProbe: { true }, settingsOpener: { _ in
                                               XCTFail("Permission probing must not open System Settings")
                                               return false
                                           })
        XCTAssertFalse(plugin.permissionState(for: "full-disk-access").isGranted)
        XCTAssertNotNil(plugin.permissionState(for: "full-disk-access").footnote)
        plugin.activate(context: .init(pluginID: AppUninstallerPlugin.pluginID))
        defer { plugin.deactivate(reason: .disabled) }

        try await eventually { plugin.permissionState(for: "full-disk-access").isGranted }
        XCTAssertNil(plugin.permissionState(for: "full-disk-access").footnote)
    }

    func testPermissionGuidanceButtonOpensFullDiskAccessSettings() {
        let controller = makeController()
        var opened: [URL] = []
        let plugin = AppUninstallerPlugin(controller: controller, localization: .init(bundle: .main),
                                           permissionProbe: { false }, settingsOpener: { opened.append($0); return true })
        plugin.requestPermissionGuidance = { _ in XCTFail("An explicit guidance click must not use the background state callback") }

        controller.openFullDiskAccess?()
        plugin.handlePermissionAction(id: "unrelated")

        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
        XCTAssertFalse(plugin.permissionState(for: "full-disk-access").isGranted)
    }

    func testCanonicalAndPanelActionsOnlyOpenReview() async throws {
        let controller = makeController()
        let plugin = AppUninstallerPlugin(controller: controller, localization: .init(bundle: .main),
                                           permissionProbe: { false }, settingsOpener: { _ in false })
        var presentations = 0
        plugin.requestSettingsPresentation = { presentations += 1 }
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(plugin.actionDefinitions.count, 1)
        XCTAssertEqual(definition.key.actionID, "open-review")
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        let reference = ActionReference(key: definition.key)
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        let handle = try plugin.beginAction(.init(reference: reference, source: .unifiedSearch, mode: .foreground))
        let result = await handle.result()
        plugin.handleAction(.invokeAction(controlID: "execute"))

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presentations, 2)
        XCTAssertFalse(controller.isScanning)
        XCTAssertFalse(controller.isRemoving)
        XCTAssertNil(controller.pendingPlan)
        XCTAssertNil(controller.selectedPath)
    }

    func testActionRejectsUnknownKeysSchemasAndPathParameters() async throws {
        let plugin = AppUninstallerPlugin(controller: makeController(), localization: .init(bundle: .main),
                                           permissionProbe: { false }, settingsOpener: { _ in false })
        plugin.requestSettingsPresentation = { XCTFail("Invalid actions must not present or execute") }
        let key = ActionKey(providerID: AppUninstallerPlugin.pluginID, actionID: AppUninstallerPlugin.reviewActionID)
        let invalid = [
            ActionReference(key: .init(providerID: AppUninstallerPlugin.pluginID, actionID: "remove")),
            ActionReference(key: .init(providerID: "other-provider", actionID: key.actionID)),
            ActionReference(key: key, schemaVersion: 2),
            ActionReference(key: key, parameters: try .init(["path": .string("/arbitrary.app")]))
        ]
        for reference in invalid {
            XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
            let handle = try plugin.beginAction(.init(reference: reference, source: .manual, mode: .foreground))
            let result = await handle.result()
            XCTAssertEqual(result, .failed(message: PluginKitLocalization.actionUnavailable))
        }
    }

    func testHomebrewHandoffNavigatesWithoutExecutingAnAction() {
        let controller = makeController()
        let plugin = AppUninstallerPlugin(controller: controller, localization: .init(bundle: .main),
                                           permissionProbe: { false }, settingsOpener: { _ in false })
        var destinations: [String] = []
        plugin.actionExecutionHostContext = .init(
            item: { _ in nil },
            execute: { _, _ in XCTFail("Homebrew handoff must only navigate"); return .cancelled },
            openProviderSettings: { destinations.append($0) }
        )

        controller.openHomebrew?()

        XCTAssertEqual(destinations, ["homebrew"])
        XCTAssertFalse(controller.isRemoving)
    }

    private func makeController() -> AppUninstallerController {
        AppUninstallerController(service: NeverPluginReview(), processProvider: { .init(paths: [], complete: true) })
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected asynchronous permission state was not published", file: file, line: line)
    }
}

private struct NeverPluginReview: UninstallReviewProviding {
    func review(_ path: String) async throws -> UninstallScan {
        XCTFail("Navigation tests must not scan applications")
        throw AppUninstallerError.blocked
    }
    func installedApplications() async throws -> UninstallInventory {
        XCTFail("Navigation tests must not inventory applications")
        throw AppUninstallerError.blocked
    }
}
