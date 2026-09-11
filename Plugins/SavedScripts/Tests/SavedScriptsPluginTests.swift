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

    func testPrimaryPanelSupportsDirectRunAndManagerWithoutOtherActionSurfaces() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        let script = try plugin.store.save(SavedScript(
            name: "Panel Script",
            kind: .sh,
            source: "echo panel"
        )).get()
        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.first?.id, script.actionID)
        XCTAssertEqual(controls.first?.actionTitle, "Panel Script")
        XCTAssertEqual(controls.last?.id, "open-manager")
    }

    func testPrimaryPanelShowsAnExecutionIndicatorWhileAScriptRuns() throws {
        var now = Date(timeIntervalSince1970: 100)
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub(),
            indicatorNow: { now }
        )
        let script = try plugin.store.save(SavedScript(
            name: "Long Task",
            kind: .zsh,
            source: "sleep 1"
        )).get()

        XCTAssertNil(plugin.primaryPanelIndicator)
        _ = plugin.executionStore.begin(script)

        XCTAssertEqual(plugin.primaryPanelIndicator?.systemImage, "progress.indicator")
        XCTAssertFalse(plugin.primaryPanelIndicator?.text.isEmpty ?? true)

        let runID = try XCTUnwrap(plugin.executionStore.record(for: script.id)?.id)
        plugin.executionStore.finish(
            scriptID: script.id,
            runID: runID,
            status: .succeeded,
            now: now
        )
        XCTAssertEqual(plugin.primaryPanelIndicator?.systemImage, "checkmark.circle.fill")

        now.addTimeInterval(7.9)
        XCTAssertEqual(plugin.primaryPanelIndicator?.systemImage, "checkmark.circle.fill")

        now.addTimeInterval(0.1)
        XCTAssertNil(plugin.primaryPanelIndicator)
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

    func testActionReferenceBackupDispositionFollowsSourceOptIn() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        let included = try plugin.store.save(SavedScript(
            name: "Included",
            kind: .zsh,
            source: "echo included",
            includeSourceInBackup: true
        )).get()
        let excluded = try plugin.store.save(SavedScript(
            name: "Excluded",
            kind: .zsh,
            source: "echo excluded",
            includeSourceInBackup: false
        )).get()

        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: included.actionID)
            )),
            .requiresPluginPreferences
        )
        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: excluded.actionID)
            )),
            .excluded
        )

        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        XCTAssertEqual(
            plugin.actionReferences(inPortablePreferences: backup),
            [ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: included.actionID)
            )]
        )
        XCTAssertNil(plugin.actionReferences(inPortablePreferences: Data("invalid".utf8)))
    }

    func testCanonicalActionAllowsRunnerCleanupAfterScriptDeadline() async throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: DelayedSavedScriptRunnerStub(
                delay: .milliseconds(1_200),
                result: SavedScriptProcessResult(
                    exitCode: 0,
                    standardOutput: "done\n",
                    standardError: "",
                    outputWasTruncated: false
                )
            )
        )
        let script = try plugin.store.save(SavedScript(
            name: "Near Deadline",
            kind: .zsh,
            source: "print done",
            timeoutSeconds: 1,
            confirmOutsideManager: false
        )).get()
        let reference = ActionReference(
            key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
        )
        let registry = ActionRegistry()
        registry.synchronize([
            ActionProviderRegistration(
                providerID: plugin.metadata.id,
                identity: ObjectIdentifier(plugin),
                definitions: plugin.actionDefinitions,
                catalogEntries: plugin.actionCatalogEntries,
                availability: plugin.actionAvailability(for:),
                begin: { invocation in
                    do {
                        return .success(try plugin.beginAction(invocation))
                    } catch {
                        return .failure(.providerFailure(error.localizedDescription))
                    }
                }
            ),
        ])
        let executor = ActionExecutor(registry: registry)

        let outcome = await executor.execute(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))

        XCTAssertEqual(outcome, .completed(.succeeded(message: "done")))
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

    func testRestoringChangedDefinitionCancelsItsActiveExecution() async throws {
        let started = expectation(description: "redefined script started")
        let checkpoint = expectation(description: "redefined script reached cancellation checkpoint")
        let runner = CheckpointSavedScriptRunnerStub(
            onStart: { started.fulfill() },
            onCheckpoint: { checkpoint.fulfill() }
        )
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        var script = try plugin.store.save(SavedScript(
            name: "Versioned",
            kind: .zsh,
            source: "echo original",
            includeSourceInBackup: true
        )).get()
        let originalBackup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        script.source = "sleep 60"
        script = try plugin.store.save(script).get()
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .workflow,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: originalBackup))
        await runner.releaseCheckpoint()
        await fulfillment(of: [checkpoint], timeout: 1)
        let wasCancelledAtCheckpoint = await runner.wasCancelledAtCheckpoint()
        if wasCancelledAtCheckpoint != true {
            plugin.cancelExecution(scriptID: script.id)
        }
        let result = await resultTask.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(wasCancelledAtCheckpoint, true)
        XCTAssertEqual(plugin.store.script(id: script.id)?.source, "echo original")
    }

    func testRestoringLibraryWithoutActiveScriptCancelsItsExecution() async throws {
        let started = expectation(description: "removed script started")
        let checkpoint = expectation(description: "removed script reached cancellation checkpoint")
        let runner = CheckpointSavedScriptRunnerStub(
            onStart: { started.fulfill() },
            onCheckpoint: { checkpoint.fulfill() }
        )
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        let script = try plugin.store.save(SavedScript(
            name: "Removed During Restore",
            kind: .zsh,
            source: "sleep 60",
            includeSourceInBackup: true
        )).get()
        let emptyLibrary = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        let emptyBackup = try XCTUnwrap(emptyLibrary.makePortablePreferencesBackup())
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .workflow,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: emptyBackup))
        await runner.releaseCheckpoint()
        await fulfillment(of: [checkpoint], timeout: 1)
        let wasCancelledAtCheckpoint = await runner.wasCancelledAtCheckpoint()
        if wasCancelledAtCheckpoint != true {
            plugin.cancelExecution(scriptID: script.id)
        }
        let result = await resultTask.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(wasCancelledAtCheckpoint, true)
        XCTAssertNil(plugin.store.script(id: script.id))
    }

    func testFailedRestoreDoesNotCancelActiveExecution() async throws {
        let storage = SavedScriptsTestStorage()
        let started = expectation(description: "script started before failed restore")
        let checkpoint = expectation(description: "failed restore cancellation checkpoint")
        let runner = CheckpointSavedScriptRunnerStub(
            onStart: { started.fulfill() },
            onCheckpoint: { checkpoint.fulfill() }
        )
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(pluginID: "saved-scripts", storage: storage),
            runner: runner
        )
        var script = try plugin.store.save(SavedScript(
            name: "Keep Running",
            kind: .zsh,
            source: "echo original",
            includeSourceInBackup: true
        )).get()
        let originalBackup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        script.source = "sleep 60"
        script = try plugin.store.save(script).get()
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .workflow,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        await fulfillment(of: [started], timeout: 1)

        storage.blocksWrites = true
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: originalBackup))
        XCTAssertEqual(plugin.store.script(id: script.id)?.source, "sleep 60")

        await runner.releaseCheckpoint()
        await fulfillment(of: [checkpoint], timeout: 1)
        let wasCancelledByRestore = await runner.wasCancelledAtCheckpoint()
        plugin.cancelExecution(scriptID: script.id)
        let result = await resultTask.value

        XCTAssertEqual(wasCancelledByRestore, false)
        XCTAssertEqual(result, .cancelled)
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

    func testFailedScriptSaveDoesNotCancelItsActiveExecution() async throws {
        let storage = SavedScriptsTestStorage()
        let runner = SuspendingSavedScriptRunnerStub()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(pluginID: "saved-scripts", storage: storage),
            runner: runner
        )
        var script = try plugin.store.save(SavedScript(
            name: "Rejected Redefinition",
            kind: .zsh,
            source: "sleep 60"
        )).get()
        let originalSource = script.source
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
        script.source = "echo rejected"
        guard case .failure = plugin.saveScript(script) else {
            return XCTFail("expected persistence failure")
        }
        await Task.yield()

        let wasCancelledBeforeCleanup = await runner.wasCancelled()
        XCTAssertFalse(wasCancelledBeforeCleanup)
        XCTAssertEqual(plugin.store.script(id: script.id)?.source, originalSource)
        plugin.cancelExecution(scriptID: script.id)
        let result = await resultTask.value
        XCTAssertEqual(result, .cancelled)
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

private actor CheckpointSavedScriptRunnerStub: SavedScriptRunning {
    private let onStart: @Sendable () -> Void
    private let onCheckpoint: @Sendable () -> Void
    private var releaseWasRequested = false
    private var checkpointContinuation: CheckedContinuation<Void, Never>?
    private var cancellationAtCheckpoint: Bool?

    init(
        onStart: @escaping @Sendable () -> Void,
        onCheckpoint: @escaping @Sendable () -> Void
    ) {
        self.onStart = onStart
        self.onCheckpoint = onCheckpoint
    }

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        onStart()
        if !releaseWasRequested {
            await withCheckedContinuation { continuation in
                if releaseWasRequested {
                    continuation.resume()
                } else {
                    checkpointContinuation = continuation
                }
            }
        }

        cancellationAtCheckpoint = Task.isCancelled
        onCheckpoint()
        try await Task.sleep(for: .seconds(60))
        return SavedScriptProcessResult(
            exitCode: 0,
            standardOutput: "",
            standardError: "",
            outputWasTruncated: false
        )
    }

    func releaseCheckpoint() {
        releaseWasRequested = true
        checkpointContinuation?.resume()
        checkpointContinuation = nil
    }

    func wasCancelledAtCheckpoint() -> Bool? {
        cancellationAtCheckpoint
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

private actor DelayedSavedScriptRunnerStub: SavedScriptRunning {
    let delay: Duration
    let result: SavedScriptProcessResult

    init(delay: Duration, result: SavedScriptProcessResult) {
        self.delay = delay
        self.result = result
    }

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        try await Task.sleep(for: delay)
        return result
    }
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
