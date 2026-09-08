// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import XCTest
import MacToolsPluginKit
@testable import MenuBarHiddenPlugin

@MainActor
final class MenuBarHiddenPluginTests: XCTestCase {
    func testActionCatalogPublishesEnabledAndDisabledChoices() throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key, ActionKey(providerID: "menu-bar-hidden", actionID: "set-enabled"))
        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertTrue(definition.capabilities.contains(.background))
        XCTAssertEqual(plugin.actionCatalogEntries.count, 2)
        XCTAssertEqual(
            plugin.actionCatalogEntries.compactMap { $0.reference.parameters["enabled"] },
            [.boolean(true), .boolean(false)]
        )
    }

    func testActionRejectsMissingAndInvalidParameters() async throws {
        let plugin = makePlugin()
        let missing = ActionReference(
            key: ActionKey(providerID: "menu-bar-hidden", actionID: "set-enabled")
        )
        let invalid = ActionReference(
            key: ActionKey(providerID: "menu-bar-hidden", actionID: "set-enabled"),
            parameters: try ActionParameterSet(["enabled": .string("yes")])
        )

        for reference in [missing, invalid] {
            let result = try await plugin.beginAction(
                ActionInvocation(reference: reference, source: .test, mode: .background)
            ).result()
            guard case .failed = result else {
                return XCTFail("Expected invalid parameters to fail")
            }
        }
    }

    func testActionsAreIdempotentWithoutActivatingTheMenuBarController() async throws {
        let plugin = makePlugin()
        let enabled = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let disabled = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        for reference in [enabled, enabled, disabled, disabled] {
            let result = try await plugin.beginAction(
                ActionInvocation(reference: reference, source: .test, mode: .background)
            ).result()
            XCTAssertEqual(result, .succeeded())
        }

        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testActionDefersMutationUntilExecutionAndFailsClosedOnRejectedWrite() async throws {
        let storage = MenuBarHiddenTestStorage()
        let plugin = makePlugin(storage: storage)
        let enabled = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: enabled, source: .test, mode: .background)
        )

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        storage.enqueueWriteBehaviors([.ignore], forKey: "is-enabled")

        let result = await handle.result()

        guard case .failed = result else {
            return XCTFail("Expected rejected persistence to fail the action")
        }
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNil(storage.object(forKey: "is-enabled"))
    }

    func testActionRejectsWrongTypedPersistedStateWithoutOverwritingIt() async throws {
        let storage = MenuBarHiddenTestStorage()
        storage.set("invalid", forKey: "is-enabled")
        let plugin = makePlugin(storage: storage)
        let enabled = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: enabled, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected recovery-required state to fail the action")
        }
        XCTAssertEqual(storage.object(forKey: "is-enabled") as? String, "invalid")
    }

    func testActionReconcilesToDurableStateWhenRollbackFails() async throws {
        let storage = MenuBarHiddenTestStorage()
        storage.set(true, forKey: "is-enabled")
        let plugin = makePlugin(storage: storage)
        let disabled = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)
        storage.enqueueWriteBehaviors([.corrupt, .ignore], forKey: "is-enabled")

        let result = try await plugin.beginAction(
            ActionInvocation(reference: disabled, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected failed rollback to fail the action")
        }
        XCTAssertEqual(storage.object(forKey: "is-enabled") as? String, "corrupt")
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    private func makePlugin(storage providedStorage: MenuBarHiddenTestStorage? = nil) -> MenuBarHiddenPlugin {
        let storage = providedStorage ?? MenuBarHiddenTestStorage()
        return MenuBarHiddenPlugin(
            context: PluginRuntimeContext(
                pluginID: "menu-bar-hidden",
                storage: storage
            )
        )
    }
}

@MainActor
private final class MenuBarHiddenTestStorage: PluginStorage {
    enum WriteBehavior {
        case accept
        case ignore
        case corrupt
    }

    private var values: [String: Any] = [:]
    private var writeBehaviors: [String: [WriteBehavior]] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        let behavior = writeBehaviors[key]?.isEmpty == false
            ? writeBehaviors[key]!.removeFirst()
            : .accept
        switch behavior {
        case .accept:
            values[key] = value
        case .ignore:
            break
        case .corrupt:
            values[key] = "corrupt"
        }
    }
    func enqueueWriteBehaviors(_ behaviors: [WriteBehavior], forKey key: String) {
        writeBehaviors[key, default: []].append(contentsOf: behaviors)
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else { return }
        values[key] = value
    }
}
