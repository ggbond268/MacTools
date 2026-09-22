import MacToolsPluginKit
import XCTest
@testable import MacTools
@testable import SavedScriptsPlugin

@MainActor
final class SavedScriptsPluginTests: XCTestCase {
    func testEverySavedScriptBecomesAStableCanonicalAction() throws {
        let storage = SavedScriptsTestStorage()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(pluginID: "saved-scripts", storage: storage),
            runner: SavedScriptRunnerStub()
        )
        let script = try plugin.store.save(SavedScript(
            name: "Daily Report",
            kind: .zsh,
            source: "echo report",
            confirmOutsideManager: true,
            allowExternalInvocation: false
        )).get()

        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.providerID, "saved-scripts")
        XCTAssertEqual(definition.key.actionID, script.actionID)
        XCTAssertEqual(definition.title, "Daily Report")
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertNotNil(definition.confirmation)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertFalse(definition.capabilities.contains(.automatic))
        XCTAssertTrue(definition.capabilities.contains(.cancellable))
        XCTAssertTrue(definition.capabilities.contains(.reportsProgress))

        let catalogEntry = try XCTUnwrap(plugin.actionCatalogEntries.first)
        XCTAssertEqual(catalogEntry.reference.key.actionID, script.actionID)
        XCTAssertEqual(catalogEntry.title, "Daily Report")
        XCTAssertEqual(catalogEntry.subtitle, "zsh")
    }

    func testExternalInvocationIsAlwaysConfirmedWhenExplicitlyEnabled() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        _ = try plugin.store.save(SavedScript(
            name: "External",
            kind: .appleScript,
            source: "return 1",
            confirmOutsideManager: false,
            allowExternalInvocation: true
        )).get()

        let template = try PluginManifestActionAssertions.dynamicTemplate(
            pluginDirectoryName: "SavedScripts",
            id: "run-script"
        )
        XCTAssertEqual(template["riskVariesByEntry"] as? Bool, true)
        XCTAssertEqual(template["automaticEligibilityVariesByEntry"] as? Bool, true)
        XCTAssertEqual(template["externalInvocation"] as? String, "configurable")
        XCTAssertTrue(
            Set(template["surfaces"] as? [String] ?? []).isSuperset(
                of: ["run-link", "automatic-rule"]
            )
        )

        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(definition.risk, .safe)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertTrue(definition.capabilities.contains(.automatic))
        XCTAssertNotNil(definition.confirmation)
    }

    func testActionExecutesScriptAndCapturesOutputForStandaloneLibrary() async throws {
        let runner = SavedScriptRunnerStub(result: SavedScriptProcessResult(
            exitCode: 0,
            standardOutput: "done\n",
            standardError: "",
            outputWasTruncated: false
        ))
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        let script = try plugin.store.save(SavedScript(
            name: "Run Me",
            kind: .bash,
            source: "echo done"
        )).get()
        let reference = ActionReference(
            key: ActionKey(providerID: "saved-scripts", actionID: script.actionID)
        )

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .workflow,
            mode: .background
        ))
        let result = await handle.result()
        let receivedScriptIDs = await runner.receivedScriptIDs()

        XCTAssertEqual(result, .succeeded(message: "done"))
        XCTAssertEqual(receivedScriptIDs, [script.id])
        XCTAssertEqual(plugin.executionStore.record(for: script.id)?.status, .succeeded)
        XCTAssertEqual(plugin.executionStore.record(for: script.id)?.standardOutput, "done\n")
    }

    func testPortablePreferencesFollowPerScriptOptIn() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        _ = try plugin.store.save(SavedScript(
            name: "Backup",
            kind: .zsh,
            source: "echo backup",
            confirmOutsideManager: false,
            allowExternalInvocation: true,
            includeSourceInBackup: true
        )).get()

        let data = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let restored = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        restored.restorePortablePreferences(from: data)

        XCTAssertEqual(restored.store.scripts.map(\.name), ["Backup"])
        XCTAssertEqual(restored.actionDefinitions.first?.risk, .confirmationRequired)
        XCTAssertEqual(restored.actionDefinitions.first?.externalInvocationPolicy, .unavailable)
    }

    func testDeactivationCancelsCanonicalExecutionOwnedByThePlugin() async throws {
        let runner = SuspendingSavedScriptRunnerStub()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        let script = try plugin.store.save(SavedScript(
            name: "Long Running",
            kind: .zsh,
            source: "sleep 60"
        )).get()
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .workflow,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        for _ in 0..<50 {
            if await runner.didStart() { break }
            await Task.yield()
        }

        plugin.deactivate(reason: .hostShutdown)
        let result = await resultTask.value
        let wasCancelled = await runner.wasCancelled()

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(plugin.executionStore.record(for: script.id)?.status, .cancelled)
    }

    func testSavingChangedScriptCancelsItsActiveExecutionAfterPersistence() async throws {
        let runner = SuspendingSavedScriptRunnerStub()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        var script = try plugin.store.save(SavedScript(
            name: "Redefine While Running",
            kind: .zsh,
            source: "sleep 60"
        )).get()
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .workflow,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        for _ in 0..<50 where !(await runner.didStart()) { await Task.yield() }

        script.source = "echo changed"
        _ = try plugin.saveScript(script).get()

        let result = await resultTask.value
        let wasCancelled = await runner.wasCancelled()
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(plugin.store.script(id: script.id)?.source, "echo changed")
    }

    func testDeletingScriptCancelsCanonicalExecutionAfterPersistence() async throws {
        let runner = SuspendingSavedScriptRunnerStub()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        let script = try plugin.store.save(SavedScript(
            name: "Delete While Running",
            kind: .zsh,
            source: "sleep 60"
        )).get()
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .actionGrid,
            mode: .foreground
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        for _ in 0..<50 {
            if await runner.didStart() { break }
            await Task.yield()
        }

        XCTAssertTrue(plugin.deleteScript(id: script.id))

        let result = await resultTask.value
        let wasCancelled = await runner.wasCancelled()
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertNil(plugin.executionStore.record(for: script.id))
    }

    func testFailedScriptDeleteDoesNotCancelExecutionOrRemoveRecord() async throws {
        let storage = SavedScriptsTestStorage()
        let runner = SuspendingSavedScriptRunnerStub()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(pluginID: "saved-scripts", storage: storage),
            runner: runner
        )
        let script = try plugin.store.save(SavedScript(
            name: "Rejected Delete",
            kind: .zsh,
            source: "sleep 60"
        )).get()
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .workflow,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        for _ in 0..<50 where !(await runner.didStart()) { await Task.yield() }

        storage.blocksWrites = true
        XCTAssertFalse(plugin.deleteScript(id: script.id))
        await Task.yield()

        XCTAssertNotNil(plugin.store.script(id: script.id))
        XCTAssertNotNil(plugin.executionStore.record(for: script.id))
        let wasCancelledBeforeCleanup = await runner.wasCancelled()
        XCTAssertFalse(wasCancelledBeforeCleanup)
        plugin.cancelExecution(scriptID: script.id)
        let result = await resultTask.value
        XCTAssertEqual(result, .cancelled)
    }
}

private actor SuspendingSavedScriptRunnerStub: SavedScriptRunning {
    private var started = false
    private var cancelled = false

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return SavedScriptProcessResult(
                exitCode: 0,
                standardOutput: "",
                standardError: "",
                outputWasTruncated: false
            )
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func didStart() -> Bool { started }
    func wasCancelled() -> Bool { cancelled }
}

private actor SavedScriptRunnerStub: SavedScriptRunning {
    private let result: SavedScriptProcessResult
    private var scriptIDs: [UUID] = []

    init(result: SavedScriptProcessResult = SavedScriptProcessResult(
        exitCode: 0,
        standardOutput: "",
        standardError: "",
        outputWasTruncated: false
    )) {
        self.result = result
    }

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        scriptIDs.append(script.id)
        return result
    }

    func receivedScriptIDs() -> [UUID] {
        scriptIDs
    }
}
