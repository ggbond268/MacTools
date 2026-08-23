import Foundation
import MacToolsPluginKit
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsPluginTests: XCTestCase {
    func testPublishesEveryDiscoveredShortcutAcrossRename() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Old")])
        let plugin = makePlugin(runner: runner)

        await plugin.controller.performRefresh()
        let original = try XCTUnwrap(plugin.actionDefinitions.first)
        await runner.setShortcuts([AppleShortcutItem(id: id, name: "New")])
        await plugin.controller.performRefresh()
        let renamed = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(original.key.actionID, "run.\(id.uuidString.lowercased())")
        XCTAssertEqual(original.key, renamed.key)
        XCTAssertEqual(renamed.title, "New")
        XCTAssertEqual(renamed.risk, .confirmationRequired)
    }

    func testRemovingShortcutUnpublishesIt() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Temporary")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        XCTAssertEqual(plugin.actionDefinitions.count, 1)

        await runner.setShortcuts([])
        await plugin.controller.performRefresh()

        XCTAssertTrue(plugin.actionDefinitions.isEmpty)
        XCTAssertTrue(plugin.actionCatalogEntries.isEmpty)
    }

    func testActionCatalogUsesFolderNamesAndOmitsRootSubtitle() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Home")
        let rootShortcut = AppleShortcutItem(id: UUID(), name: "Root")
        let folderShortcut = AppleShortcutItem(id: UUID(), name: "Inside Folder")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [rootShortcut, folderShortcut],
            folders: [folder],
            memberships: [folder.id: .success([folderShortcut])]
        )
        let plugin = makePlugin(runner: runner)

        await plugin.controller.performRefresh()

        let entriesByTitle = Dictionary(
            uniqueKeysWithValues: plugin.actionCatalogEntries.map { ($0.title, $0) }
        )
        XCTAssertNil(entriesByTitle["Root"]?.subtitle)
        XCTAssertEqual(entriesByTitle["Inside Folder"]?.subtitle, "Home")
    }

    func testAllShortcutsPublishConfirmedRunLinks() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Secure")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()

        var definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(definition.confirmation)

        try plugin.store.setRequiresConfirmation(false, for: id).get()
        definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(definition.risk, .safe)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(definition.confirmation)
    }

    func testPolicyChangesRequestImmediateSafetyRegistryRebuild() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Safety")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        var safetyChangeCount = 0
        plugin.onActionSafetyStateChange = { safetyChangeCount += 1 }

        try plugin.store.setRequiresConfirmation(false, for: id).get()

        XCTAssertEqual(safetyChangeCount, 1)
    }

    func testActionExecutesByIdentifierAndCapturesOutput() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [AppleShortcutItem(id: id, name: "Run")],
            runResult: .success(AppleShortcutsCommandResult(
                exitCode: 0,
                standardOutput: "done\n",
                standardError: "",
                outputWasTruncated: false
            ))
        )
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .workflow,
            mode: .background
        ))
        let result = await handle.result()
        let runIDs = await runner.observedRunIDs()

        XCTAssertEqual(result, .succeeded(message: "done"))
        XCTAssertEqual(runIDs, [id])
    }

    func testPortablePreferencesBackUpSafetyExceptions() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Backup")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setRequiresConfirmation(false, for: id).get()
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())

        XCTAssertEqual(plugin.actionReferences(inPortablePreferences: backup)?.first?.key.actionID,
                       AppleShortcutsStore.actionID(for: id))

        let restored = makePlugin(runner: AppleShortcutsRunnerStub())
        XCTAssertTrue(restored.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertFalse(restored.store.policy(for: id).requiresConfirmation)
    }

    func testProviderRejectsNoncanonicalUppercaseActionIdentity() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Canonical")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        let reference = ActionReference(key: ActionKey(
            providerID: plugin.metadata.id,
            actionID: "run.\(id.uuidString)"
        ))

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertEqual(plugin.backupDisposition(for: reference), .excluded)
    }

    func testActionsAreExcludedFromAppIntentsToPreventShortcutRecursion() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [AppleShortcutItem(id: id, name: "No Recursion")]
        )
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(
            plugin.exposurePolicy(for: reference, on: .appIntents),
            .excluded
        )
        XCTAssertEqual(
            plugin.exposurePolicy(
                for: reference,
                on: ActionExposureSurface(rawValue: "future-surface")
            ),
            .automatic
        )
    }

    private func makePlugin(runner: AppleShortcutsRunnerStub) -> AppleShortcutsPlugin {
        AppleShortcutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "apple-shortcuts",
                storage: AppleShortcutsTestStorage()
            ),
            runner: runner,
            visualMetadataLoader: AppleShortcutsVisualMetadataStub()
        )
    }
}
