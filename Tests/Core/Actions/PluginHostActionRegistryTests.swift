import Carbon
import MacToolsPluginKit
@testable import SavedScriptsPlugin
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostActionRegistryTests: XCTestCase {
    func testExternalDiscoveryPreparationAwaitsProviderAndPublishesFinalCatalog() async {
        let plugin = PreparingActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        XCTAssertNil(host.actionRegistry.definition(for: plugin.actionKey))

        let preparation = Task { @MainActor in
            await host.prepareActionCatalogForExternalDiscovery()
        }
        for _ in 0 ..< 100 where !plugin.isPreparing {
            await Task.yield()
        }

        XCTAssertTrue(plugin.isPreparing)
        XCTAssertNil(host.actionRegistry.definition(for: plugin.actionKey))

        plugin.finishPreparation()
        await preparation.value

        XCTAssertEqual(host.actionRegistry.definition(for: plugin.actionKey), plugin.definition)
        XCTAssertEqual(
            host.actionRegistry.catalogEntries.map(\.reference.key).filter {
                $0 == plugin.actionKey
            },
            [plugin.actionKey]
        )
    }

    func testExternalDiscoveryPreparationTimesOutStalledProviderAndContinues() async {
        let stalledPlugin = PreparingActionTestPlugin(
            id: "stalled-provider",
            initiallyPrepared: true
        )
        let readyPlugin = PreparingActionTestPlugin(id: "ready-provider")
        let host = makePluginHostForTests(plugins: [stalledPlugin, readyPlugin])
        XCTAssertEqual(host.actionRegistry.definition(for: stalledPlugin.actionKey), stalledPlugin.definition)

        let preparation = Task { @MainActor in
            await host.prepareActionCatalogForExternalDiscovery(
                providerTimeout: .milliseconds(50)
            )
        }
        for _ in 0 ..< 100 where !stalledPlugin.isPreparing {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(stalledPlugin.isPreparing)

        for _ in 0 ..< 100 where !readyPlugin.isPreparing {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(readyPlugin.isPreparing)
        readyPlugin.finishPreparation()
        await preparation.value

        XCTAssertNil(host.actionRegistry.definition(for: stalledPlugin.actionKey))
        XCTAssertEqual(host.actionRegistry.definition(for: readyPlugin.actionKey), readyPlugin.definition)
        stalledPlugin.finishPreparation()
        for _ in 0 ..< 100
        where host.actionRegistry.definition(for: stalledPlugin.actionKey) == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(host.actionRegistry.definition(for: stalledPlugin.actionKey), stalledPlugin.definition)
    }

    func testMultipleStalledProvidersShareOneOverallTimeoutWindow() async {
        let firstPlugin = PreparingActionTestPlugin(id: "first-stalled-provider")
        let secondPlugin = PreparingActionTestPlugin(id: "second-stalled-provider")
        let host = makePluginHostForTests(plugins: [firstPlugin, secondPlugin])
        let clock = ContinuousClock()
        let start = clock.now

        await host.prepareActionCatalogForExternalDiscovery(
            providerTimeout: .milliseconds(50)
        )

        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(150))
        XCTAssertEqual(firstPlugin.preparationCount, 1)
        XCTAssertEqual(secondPlugin.preparationCount, 1)
        firstPlugin.finishPreparation()
        secondPlugin.finishPreparation()
    }

    func testStalePreparationCompletionCannotClearNewerTimeoutForSameProvider() async {
        let plugin = PreparingActionTestPlugin(
            id: "reprepared-provider",
            initiallyPrepared: true
        )
        let host = makePluginHostForTests(plugins: [plugin])

        await host.prepareActionCatalogForExternalDiscovery(
            providerTimeout: .milliseconds(20)
        )
        await host.prepareActionCatalogForExternalDiscovery(
            providerTimeout: .milliseconds(20)
        )
        XCTAssertEqual(plugin.preparationCount, 2)
        XCTAssertNil(host.actionRegistry.definition(for: plugin.actionKey))

        plugin.finishPreparation()
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(host.actionRegistry.definition(for: plugin.actionKey))

        plugin.finishPreparation()
        for _ in 0 ..< 100
        where host.actionRegistry.definition(for: plugin.actionKey) == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(host.actionRegistry.definition(for: plugin.actionKey), plugin.definition)
    }

    func testSupersededPreparationCancelsEveryObsoleteProviderRace() async {
        let firstPlugin = PreparingActionTestPlugin(id: "first-overlap-provider")
        let secondPlugin = PreparingActionTestPlugin(id: "second-overlap-provider")
        let host = makePluginHostForTests(plugins: [firstPlugin, secondPlugin])

        let firstPass = Task { @MainActor in
            await host.prepareActionCatalogForExternalDiscovery(providerTimeout: .seconds(1))
        }
        for _ in 0 ..< 100
        where firstPlugin.preparationCount < 1 || secondPlugin.preparationCount < 1 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let secondPass = Task { @MainActor in
            await host.prepareActionCatalogForExternalDiscovery(providerTimeout: .seconds(1))
        }
        for _ in 0 ..< 100
        where firstPlugin.preparationCount < 2 || secondPlugin.preparationCount < 2 {
            try? await Task.sleep(for: .milliseconds(2))
        }

        await firstPass.value
        for _ in 0 ..< 100
        where firstPlugin.cancellationCount < 1 || secondPlugin.cancellationCount < 1 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(firstPlugin.cancellationCount, 1)
        XCTAssertEqual(secondPlugin.cancellationCount, 1)

        firstPlugin.finishPreparation()
        secondPlugin.finishPreparation()
        firstPlugin.finishPreparation()
        secondPlugin.finishPreparation()
        await secondPass.value
    }

    func testDirectPreparationCancellationStopsProviderWithoutLatePublication() async {
        let plugin = PreparingActionTestPlugin(id: "direct-cancellation-provider")
        let host = makePluginHostForTests(plugins: [plugin])
        let preparation = Task { @MainActor in
            await host.prepareActionCatalogForExternalDiscovery(providerTimeout: .seconds(1))
        }
        for _ in 0 ..< 100 where plugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let clock = ContinuousClock()
        let cancellationStarted = clock.now

        preparation.cancel()
        await preparation.value

        XCTAssertLessThan(
            cancellationStarted.duration(to: clock.now),
            .milliseconds(150)
        )
        for _ in 0 ..< 100 where plugin.cancellationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(plugin.cancellationCount, 1)
        XCTAssertNil(host.actionRegistry.definition(for: plugin.actionKey))

        plugin.finishPreparation()
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(host.actionRegistry.definition(for: plugin.actionKey))
    }

    func testDynamicReplacementDoesNotReprepareUnrelatedProvider() async {
        let unrelatedPlugin = PreparingActionTestPlugin(id: "unrelated-provider")
        let firstDynamicPlugin = PreparingActionTestPlugin(id: "changed-dynamic-provider")
        let replacementPlugin = PreparingActionTestPlugin(id: "changed-dynamic-provider")
        let host = makePluginHostForTests(plugins: [unrelatedPlugin])

        host.replaceDynamicPluginsForTests([firstDynamicPlugin], providerTimeout: .seconds(1))
        for _ in 0 ..< 100 where firstDynamicPlugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        host.replaceDynamicPluginsForTests([replacementPlugin], providerTimeout: .seconds(1))
        for _ in 0 ..< 100 where replacementPlugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(unrelatedPlugin.preparationCount, 0)
        firstDynamicPlugin.finishPreparation()
        replacementPlugin.finishPreparation()
        await host.waitForDynamicPluginActionCatalogPreparationForTests()
    }

    func testDynamicReplacementBeforeOldPreparationCompletesPublishesOnlyReplacement() async {
        let oldPlugin = PreparingActionTestPlugin(
            id: "replaceable-provider",
            initiallyPrepared: true,
            definitionTitle: "Old Action"
        )
        let newPlugin = PreparingActionTestPlugin(
            id: "replaceable-provider",
            definitionTitle: "New Action"
        )
        let host = makePluginHostForTests(plugins: [])

        host.replaceDynamicPluginsForTests([oldPlugin], providerTimeout: .seconds(1))
        for _ in 0 ..< 100 where oldPlugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        host.replaceDynamicPluginsForTests([newPlugin], providerTimeout: .seconds(1))
        for _ in 0 ..< 100 where newPlugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }

        oldPlugin.finishPreparation()
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(host.actionRegistry.definition(for: newPlugin.actionKey))

        newPlugin.finishPreparation()
        await host.waitForDynamicPluginActionCatalogPreparationForTests()
        XCTAssertEqual(
            host.actionRegistry.definition(for: newPlugin.actionKey)?.title,
            "New Action"
        )
    }

    func testDynamicReplacementBeforeOldTimeoutDoesNotQuarantineReplacement() async {
        let oldPlugin = PreparingActionTestPlugin(
            id: "timeout-replacement-provider",
            initiallyPrepared: true,
            definitionTitle: "Old Action"
        )
        let newPlugin = PreparingActionTestPlugin(
            id: "timeout-replacement-provider",
            definitionTitle: "New Action"
        )
        let host = makePluginHostForTests(plugins: [])

        host.replaceDynamicPluginsForTests([oldPlugin], providerTimeout: .milliseconds(30))
        for _ in 0 ..< 100 where oldPlugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        host.replaceDynamicPluginsForTests([newPlugin], providerTimeout: .seconds(1))
        for _ in 0 ..< 100 where newPlugin.preparationCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(host.actionRegistry.definition(for: newPlugin.actionKey))
        newPlugin.finishPreparation()
        await host.waitForDynamicPluginActionCatalogPreparationForTests()
        XCTAssertEqual(
            host.actionRegistry.definition(for: newPlugin.actionKey)?.title,
            "New Action"
        )
        oldPlugin.finishPreparation()
    }

    func testHostDistributesInputGestureClaimsOnlyToOtherPlugins() {
        let owner = InputGestureClaimTestPlugin(id: "gesture-owner", claims: [
            PluginInputGestureClaim(id: "trackpad.tap.3", title: "Three-Finger Tap"),
        ])
        let consumer = InputGestureConflictTestPlugin()

        _ = makePluginHostForTests(plugins: [owner, consumer])

        XCTAssertEqual(consumer.conflicts, [
            PluginInputGestureConflict(
                claim: PluginInputGestureClaim(id: "trackpad.tap.3", title: "Three-Finger Tap"),
                ownerPluginID: "gesture-owner",
                ownerPluginTitle: "gesture-owner"
            ),
        ])
    }

    func testHostRoutesOptionalPluginActionExposurePolicy() {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let reference = ActionReference(key: plugin.definition.key)

        XCTAssertEqual(
            host.actionExposurePolicy(for: reference, on: .appIntents),
            .automatic
        )

        plugin.appIntentExposurePolicy = .excluded
        XCTAssertEqual(
            host.actionExposurePolicy(for: reference, on: .appIntents),
            .excluded
        )
    }

    func testSavedScriptWithoutLocalConfirmationStillPublishesWhenRunLinksAreEnabled() throws {
        let suiteName = "PluginHostActionRegistryTests.saved-scripts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = SavedScriptsPlugin(context: PluginRuntimeContext(
            pluginID: "saved-scripts",
            storage: UserDefaultsPluginStorage(
                pluginID: "saved-scripts",
                userDefaults: defaults
            )
        ))
        let script = try plugin.store.save(SavedScript(
            name: "Test Script",
            kind: .zsh,
            source: "echo test",
            confirmOutsideManager: false,
            allowExternalInvocation: true
        )).get()

        let host = makePluginHostForTests(plugins: [plugin])
        let published = host.actionCatalogEntries.first {
            $0.reference.key == ActionKey(
                providerID: "saved-scripts",
                actionID: script.actionID
            )
        }

        XCTAssertEqual(published?.title, "Test Script")
        XCTAssertTrue(host.actionRegistryIssues.isEmpty)
    }

    func testSavedScriptSourceChangeDuringConfirmationIsRejectedBeforeExecution() async throws {
        let suiteName = "PluginHostActionRegistryTests.saved-scripts-revision.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = SavedScriptsPlugin(context: PluginRuntimeContext(
            pluginID: "saved-scripts",
            storage: UserDefaultsPluginStorage(
                pluginID: "saved-scripts",
                userDefaults: defaults
            )
        ))
        var script = try plugin.saveScript(SavedScript(
            name: "Mutable Script",
            kind: .zsh,
            source: "echo original"
        )).get()
        let host = makePluginHostForTests(plugins: [plugin])
        host.actionConfirmationService.setHandler { _ in
            script.source = "echo substituted"
            _ = plugin.saveScript(script)
            return true
        }

        let outcome = await host.actionExecutor.execute(ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: plugin.metadata.id, actionID: script.actionID)
            ),
            source: .actionGrid,
            mode: .foreground
        ))

        XCTAssertEqual(outcome, .rejected(.providerChanged))
        XCTAssertNil(plugin.executionStore.record(for: script.id))
    }

    func testHostPublishesNativeLegacyAndApplicationActionsThroughOneRegistry() async {
        let native = NativeActionTestPlugin()
        let legacy = LegacyActionTestPlugin()
        let host = makePluginHostForTests(plugins: [native, legacy])
        var presentationRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { presentationRequests.append($0) }

        let catalogKeys = Set(host.actionCatalogEntries.map(\.reference.key))
        XCTAssertTrue(host.actionRegistryIssues.isEmpty)
        XCTAssertTrue(catalogKeys.contains(native.definition.key))
        XCTAssertTrue(
            catalogKeys.contains(ActionKey(providerID: legacy.metadata.id, actionID: "sleep"))
        )
        XCTAssertTrue(
            catalogKeys.contains(
                ActionKey(
                    providerID: "mactools",
                    actionID: AppShortcutAction.openSettings.rawValue
                )
            )
        )

        let nativeOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: native.definition.key),
                source: .test,
                mode: .background
            )
        )
        XCTAssertEqual(nativeOutcome, .completed(.succeeded(message: "native")))
        XCTAssertEqual(native.beginCount, 1)

        let legacyReference = ActionReference(
            key: ActionKey(providerID: legacy.metadata.id, actionID: "sleep")
        )
        XCTAssertFalse(
            host.actionRegistry.definition(for: legacyReference.key)?
                .capabilities.contains(.background) ?? true
        )
        let backgroundLegacyOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: legacyReference,
                source: .test,
                mode: .background
            )
        )
        XCTAssertEqual(backgroundLegacyOutcome, .rejected(.backgroundExecutionUnsupported))
        XCTAssertTrue(legacy.performedCommandIDs.isEmpty)

        let legacyOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: legacyReference,
                source: .test,
                mode: .foreground
            )
        )
        XCTAssertEqual(legacyOutcome, .completed(.succeeded()))
        XCTAssertEqual(legacy.performedCommandIDs, ["sleep"])

        let appOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(
                    key: ActionKey(
                        providerID: "mactools",
                        actionID: AppShortcutAction.openSettings.rawValue
                    )
                ),
                source: .test,
                mode: .foreground
            )
        )
        XCTAssertEqual(appOutcome, .completed(.succeeded()))
        XCTAssertEqual(presentationRequests, [.settings(.settings)])
    }

    func testPluginStateChangeRefreshesDynamicActionShortcutCatalog() async {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let addedDefinition = ActionDefinition(
            key: ActionKey(providerID: plugin.metadata.id, actionID: "added-later"),
            title: "Added Later",
            description: "A dynamically added action.",
            systemImage: "plus"
        )

        XCTAssertFalse(host.actionShortcutCatalogItems.contains {
            $0.reference.key == addedDefinition.key
        })

        plugin.additionalDefinitions = [addedDefinition]
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: {
                $0.reference.key == addedDefinition.key
            })?.title,
            "Added Later"
        )
    }

    func testPluginStateChangeUnregistersShortcutWhenDynamicActionDisappears() async throws {
        let suiteName = "PluginHostActionRegistryTests.dynamic-removal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = NativeActionTestPlugin()
        let dynamicDefinition = ActionDefinition(
            key: ActionKey(providerID: plugin.metadata.id, actionID: "dynamic-source"),
            title: "Dynamic Source",
            description: "Switch to a dynamic source.",
            systemImage: "keyboard",
            capabilities: [.foregroundInteractive]
        )
        plugin.additionalDefinitions = [dynamicDefinition]
        let shortcutManager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let host = makeIsolatedHost(
            plugin: plugin,
            defaults: defaults,
            shortcutManager: shortcutManager,
            pluginStateChangeRebuildDelay: .milliseconds(10)
        )
        let reference = ActionReference(key: dynamicDefinition.key)
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_R),
            modifiers: [.command, .option]
        )

        XCTAssertEqual(host.setActionShortcutBinding(binding, to: reference), .success)
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)

        plugin.additionalDefinitions = []
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertTrue(registrations(for: reference, in: host, manager: shortcutManager).isEmpty)
        guard case .unavailable = host.actionShortcutCatalogItems.first(where: {
            $0.reference == reference
        })?.status else {
            return XCTFail("Expected the preserved shortcut assignment to become unavailable")
        }
    }

    func testPluginStateChangeRegistersPersistedShortcutWhenDynamicActionAppears() async throws {
        let suiteName = "PluginHostActionRegistryTests.dynamic-reappearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = NativeActionTestPlugin()
        let dynamicDefinition = ActionDefinition(
            key: ActionKey(providerID: plugin.metadata.id, actionID: "dynamic-source"),
            title: "Dynamic Source",
            description: "Switch to a dynamic source.",
            systemImage: "keyboard",
            capabilities: [.foregroundInteractive]
        )
        let reference = ActionReference(key: dynamicDefinition.key)
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_R),
            modifiers: [.command, .option]
        )
        XCTAssertEqual(
            ActionShortcutAssignmentStore(userDefaults: defaults).replaceAll([
                ActionShortcutAssignmentRecord(reference: reference, binding: binding),
            ]),
            .committed
        )
        let shortcutManager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let host = makeIsolatedHost(
            plugin: plugin,
            defaults: defaults,
            shortcutManager: shortcutManager,
            pluginStateChangeRebuildDelay: .milliseconds(10)
        )

        XCTAssertTrue(registrations(for: reference, in: host, manager: shortcutManager).isEmpty)

        plugin.additionalDefinitions = [dynamicDefinition]
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.status,
            .assigned
        )
    }

    func testPluginStateChangeSynchronizesParameterizedCatalogEntryShortcuts() async throws {
        let suiteName = "PluginHostActionRegistryTests.dynamic-parameter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = ParameterizedActionTestPlugin()
        let reference = try plugin.reference(target: "display-2")
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_R),
            modifiers: [.command, .option]
        )
        XCTAssertEqual(
            ActionShortcutAssignmentStore(userDefaults: defaults).replaceAll([
                ActionShortcutAssignmentRecord(reference: reference, binding: binding),
            ]),
            .committed
        )
        let shortcutManager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let host = makeIsolatedHost(
            plugin: plugin,
            defaults: defaults,
            shortcutManager: shortcutManager,
            pluginStateChangeRebuildDelay: .milliseconds(10)
        )

        XCTAssertTrue(registrations(for: reference, in: host, manager: shortcutManager).isEmpty)

        plugin.targets.append("display-2")
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.status,
            .assigned
        )

        plugin.targets.removeAll { $0 == "display-2" }
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertTrue(registrations(for: reference, in: host, manager: shortcutManager).isEmpty)
        guard case .unavailable = host.actionShortcutCatalogItems.first(where: {
            $0.reference == reference
        })?.status else {
            return XCTFail("Expected the removed parameterized catalog entry to become unavailable")
        }
    }

    func testActionSafetyStateChangeRebuildsRegistrySynchronously() async {
        let plugin = SafetyStateActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionRegistry.definition(for: plugin.actionKey)?.risk,
            .safe
        )
        XCTAssertEqual(
            host.actionRegistry.definition(for: plugin.actionKey)?.externalInvocationPolicy,
            .confirmAlways
        )

        plugin.requiresConfirmation = true
        plugin.allowsRunLink = false
        plugin.onActionSafetyStateChange?()

        XCTAssertEqual(
            host.actionRegistry.definition(for: plugin.actionKey)?.risk,
            .confirmationRequired
        )
        XCTAssertEqual(
            host.actionRegistry.definition(for: plugin.actionKey)?.externalInvocationPolicy,
            .unavailable
        )

        let localOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: plugin.actionKey),
                source: .manual,
                mode: .background
            ),
            confirmationService: ActionExecutorConfirmationService { false }
        )
        XCTAssertEqual(localOutcome, .rejected(.confirmationDenied))
        let runLinkOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: plugin.actionKey),
                source: .runLink,
                mode: .background
            )
        )
        XCTAssertEqual(runLinkOutcome, .rejected(.externalInvocationUnavailable))
        XCTAssertEqual(plugin.beginCount, 0)
    }

    func testConvergedShortcutAssignmentsRemainIndividuallyVisibleAndEditable() async throws {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let reference = ActionReference(key: plugin.definition.key)
        let firstID = UUID()
        let secondID = UUID()
        let firstBinding = ShortcutBinding(keyCode: 31, modifiers: [.command, .option])
        let secondBinding = ShortcutBinding(keyCode: 32, modifiers: [.command, .shift])
        XCTAssertEqual(
            host.shortcutAssignmentService.replaceAllForImport([
                ActionShortcutAssignmentRecord(
                    id: firstID,
                    reference: reference,
                    binding: firstBinding
                ),
                ActionShortcutAssignmentRecord(
                    id: secondID,
                    reference: reference,
                    binding: secondBinding
                ),
            ]),
            .success
        )

        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(
            Set(host.actionShortcutCatalogItems.filter { $0.reference == reference }
                .compactMap(\.assignmentID)),
            [firstID, secondID]
        )

        let replacement = ShortcutBinding(keyCode: 33, modifiers: [.command, .control])
        XCTAssertEqual(
            host.setActionShortcutBinding(
                replacement,
                to: reference,
                assignmentID: secondID
            ),
            .success
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignments.first(where: { $0.id == firstID })?.binding,
            firstBinding
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignments.first(where: { $0.id == secondID })?.binding,
            replacement
        )

        host.clearActionShortcut(for: reference, assignmentID: firstID)
        XCTAssertEqual(host.shortcutAssignmentService.assignments.map(\.id), [secondID])
    }

    func testNativeProviderAvailabilityIsEvaluatedAtExecutionTime() async {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.availability = .unavailable("目标已断开连接")

        let outcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: plugin.definition.key),
                source: .test,
                mode: .background
            )
        )

        XCTAssertEqual(outcome, .rejected(.unavailable("目标已断开连接")))
        XCTAssertEqual(plugin.beginCount, 0)
    }

    func testActionOwnerNavigationUsesHostSettingsRoutes() {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        XCTAssertTrue(host.presentActionOwner(for: ActionReference(
            key: ActionKey(
                providerID: "mactools",
                actionID: AppShortcutAction.toggleDashboard.rawValue
            )
        )))
        XCTAssertTrue(host.presentActionOwner(for: ActionReference(
            key: ActionKey(
                providerID: "mactools",
                actionID: AppShortcutAction.toggleFeaturePanel.rawValue
            )
        )))
        XCTAssertTrue(host.presentActionOwner(for: ActionReference(
            key: ActionKey(
                providerID: "mactools",
                actionID: AppShortcutAction.openSettings.rawValue
            )
        )))
        XCTAssertTrue(
            host.presentActionOwner(
                for: ActionReference(
                    key: ActionKey(providerID: AutomationController.providerID, actionID: "test")
                )
            )
        )
        XCTAssertFalse(
            host.presentActionOwner(
                for: ActionReference(key: ActionKey(providerID: "missing", actionID: "test"))
            )
        )
        XCTAssertEqual(
            requests,
            [
                .settings(.feature(.dashboardLayout)),
                .settings(.feature(.featurePanelLayout)),
                .settings(.general),
                .settings(.feature(.automation)),
            ]
        )
    }

    func testActionOwnerAppearanceUsesPluginMetadataAndHostFallbacks() {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionOwnerAppearance(providerID: plugin.metadata.id).systemImage,
            plugin.metadata.iconName
        )
        XCTAssertEqual(
            host.actionOwnerAppearance(providerID: "mactools").systemImage,
            "hammer"
        )
        XCTAssertEqual(
            host.actionOwnerAppearance(providerID: AutomationController.providerID).systemImage,
            "bolt.horizontal.circle"
        )
        XCTAssertEqual(
            host.actionOwnerAppearance(providerID: "missing-provider").systemImage,
            "puzzlepiece.extension"
        )
    }

    func testWorkflowActionOwnerNavigationPreservesTheExactWorkflow() throws {
        let host = makePluginHostForTests(plugins: [])
        let workflow = try XCTUnwrap(host.automationController.createWorkflow())
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        XCTAssertTrue(host.presentActionOwner(for: workflow.actionReference))
        XCTAssertEqual(requests, [.settings(.automationWorkflow(workflow.id))])
    }

    func testActionShortcutSuppressesRecursiveSyntheticRetrigger() async throws {
        let registrar = FakeCarbonHotKeyRegistrar()
        let shortcutManager = GlobalShortcutManager(registrar: registrar)
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(
            plugins: [plugin],
            globalShortcutManager: shortcutManager
        )
        let reference = ActionReference(key: plugin.definition.key)
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command, .option])
        XCTAssertEqual(host.setActionShortcutBinding(binding, to: reference), .success)
        let shortcutID = try XCTUnwrap(
            shortcutManager.debugRegistrationsForTests.first(where: {
                $0.binding == binding
            })?.shortcutID
        )
        plugin.operation = {
            shortcutManager.triggerForTests(shortcutID: shortcutID)
            await Task.yield()
            return .succeeded()
        }

        shortcutManager.triggerForTests(shortcutID: shortcutID)
        for _ in 0 ..< 20 where plugin.beginCount == 0 {
            await Task.yield()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(plugin.beginCount, 1)
    }

    func testHostAggregatesActionSurfaceAssignmentSummaries() {
        let plugin = NativeActionTestPlugin()
        plugin.summarizedReference = ActionReference(key: plugin.definition.key)
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionSurfaceAssignmentSummaries(for: plugin.summarizedReference!),
            [
                ActionSurfaceAssignmentSummary(
                    surfaceID: plugin.metadata.id,
                    surfaceTitle: plugin.metadata.title,
                    systemImage: plugin.metadata.iconName,
                    detail: "已分配"
                ),
            ]
        )
    }

    func testHostProjectsProviderOwnedActionPermissionRequirements() {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionPermissionTitles(for: ActionReference(key: plugin.definition.key)),
            ["测试权限"]
        )
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: {
                $0.reference.key == plugin.definition.key
            })?.permissionSummary,
            FeatureL10n.format("所需权限：%@", "测试权限")
        )
    }

    func testPermissionSummaryUsesSelectedRuntimeLocaleForMultiplePermissions() {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        PluginRuntimeLocalization.source.setPreference("de")
        let plugin = NativeActionTestPlugin()
        plugin.permissionTitles = ["Kamera", "Mikrofon"]
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: {
                $0.reference.key == plugin.definition.key
            })?.permissionSummary,
            FeatureL10n.format(
                "所需权限：%@",
                FeatureL10n.joined(plugin.permissionTitles)
            )
        )
        XCTAssertTrue(
            host.actionShortcutCatalogItems.first(where: {
                $0.reference.key == plugin.definition.key
            })?.permissionSummary?.contains("und") == true
        )
    }

    func testDynamicActionMetadataSwitchesLanguageWithoutReloadingPlugin() async throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let defaultsSuite = "PluginHostActionRegistryTests.metadata.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let sourcePackage = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("runtime-localized-action", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleRelativePath = "RuntimeLocalizedAction.bundle"
        try FileManager.default.createDirectory(
            at: sourcePackage.appendingPathComponent(bundleRelativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = PluginPackageManifest(
            id: RuntimeLocalizedActionTestPlugin.providerID,
            displayName: "Runtime Localized Action",
            version: "1.0.0",
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleRelativePath,
            localizedMetadata: [
                "en": PluginLocalizedMetadata(
                    displayName: "Runtime Action",
                    summary: "Switch a test state."
                ),
                "ar": PluginLocalizedMetadata(
                    displayName: "إجراء وقت التشغيل",
                    summary: "بدّل حالة اختبار."
                ),
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: sourcePackage.appendingPathComponent("plugin.json")
        )
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot.appendingPathComponent("Store", isDirectory: true),
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = try store.installPackage(from: sourcePackage)
        let plugin = RuntimeLocalizedActionTestPlugin()
        let loader = PluginHostDynamicTestLoader(plugin: plugin)
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        PluginRuntimeLocalization.source.setPreference("en")
        let host = makePluginHostForTests(
            plugins: [],
            dynamicPluginManager: manager
        )
        let reference = ActionReference(key: plugin.actionKey)
        XCTAssertEqual(host.actionSurfaceOwnerTitle(providerID: plugin.metadata.id), "Runtime Action")
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.description,
            "Switch a test state."
        )

        PluginRuntimeLocalization.source.setPreference("ar")
        for _ in 0 ..< 20 where host.localizationRevision == 0 {
            await Task.yield()
        }

        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertEqual(host.actionSurfaceOwnerTitle(providerID: plugin.metadata.id), "إجراء وقت التشغيل")
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.description,
            "بدّل حالة اختبار."
        )
    }

    func testActionBackedPluginShortcutMigratesIntoCentralEditorOnly() throws {
        let registrar = FakeCarbonHotKeyRegistrar()
        let shortcutManager = GlobalShortcutManager(registrar: registrar)
        let plugin = ActionBackedShortcutTestPlugin()
        let suiteName = "PluginHostActionRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_A),
            modifiers: [.command, .option]
        )
        let shortcutStore = ShortcutStore(userDefaults: defaults)
        shortcutStore.setCustomization(
            .custom(legacyBinding),
            for: ActionBackedShortcutTestPlugin.shortcutItemID
        )
        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: shortcutStore,
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(
                userDefaults: defaults
            ),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: shortcutManager
        )
        let reference = ActionReference(key: plugin.definition.key)

        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            legacyBinding
        )
        XCTAssertEqual(
            shortcutStore.customization(for: ActionBackedShortcutTestPlugin.shortcutItemID),
            .cleared
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignments.filter {
                $0.reference == reference
            }.count,
            1
        )
        XCTAssertFalse(host.shortcutItems.contains {
            $0.id == ActionBackedShortcutTestPlugin.shortcutItemID
        })
        XCTAssertEqual(
            host.actionShortcutSettingsItem(for: reference)?.bindingText,
            ShortcutFormatter.displayString(for: legacyBinding)
        )
        let initialRegistrations = registrations(
            for: reference,
            in: host,
            manager: shortcutManager
        )
        XCTAssertEqual(initialRegistrations.count, 1)
        XCTAssertTrue(initialRegistrations.first?.shortcutID.hasPrefix("action-shortcut.") ?? false)

        let centralEditorBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_B),
            modifiers: [.command, .option]
        )
        XCTAssertEqual(
            host.setActionShortcutBinding(centralEditorBinding, to: reference),
            .success
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            centralEditorBinding
        )
        XCTAssertEqual(
            host.actionShortcutSettingsItem(for: reference)?.bindingText,
            ShortcutFormatter.displayString(for: centralEditorBinding)
        )
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)

        let replacementBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_N),
            modifiers: [.command, .shift]
        )
        XCTAssertEqual(
            host.setActionShortcutBinding(replacementBinding, to: reference),
            .success
        )
        XCTAssertEqual(
            host.actionShortcutSettingsItem(for: reference)?.assignment.binding,
            replacementBinding
        )
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)

        host.clearActionShortcut(for: reference)
        XCTAssertNil(host.actionShortcutSettingsItem(for: reference))

        XCTAssertEqual(
            host.setActionShortcutBinding(plugin.defaultBinding, to: reference),
            .success
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            plugin.defaultBinding
        )
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)
    }

    func testCentralActionShortcutEditorKeepsConvergedAssignmentsIndividuallyEditable() throws {
        let plugin = ActionBackedShortcutTestPlugin()
        let suiteName = "PluginHostActionRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reference = ActionReference(key: plugin.definition.key)
        let first = ActionShortcutAssignmentRecord(
            reference: reference,
            binding: ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .option])
        )
        let second = ActionShortcutAssignmentRecord(
            reference: reference,
            binding: ShortcutBinding(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            ActionShortcutAssignmentStore(userDefaults: defaults).replaceAll([first, second]),
            .committed
        )
        let host = makeIsolatedHost(
            plugin: plugin,
            defaults: defaults,
            shortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        )

        XCTAssertFalse(host.shortcutItems.contains {
            $0.id == ActionBackedShortcutTestPlugin.shortcutItemID
        })
        let rows = host.actionShortcutCatalogItems.filter {
            $0.reference == reference
        }
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)

        let secondRow = try XCTUnwrap(rows.first(where: {
            $0.assignmentID == second.id
        }))
        host.clearActionShortcut(for: reference, assignmentID: secondRow.assignmentID)

        XCTAssertEqual(host.shortcutAssignmentService.assignments, [first])
        XCTAssertEqual(
            host.actionShortcutCatalogItems.filter { $0.reference == reference }.map(\.assignmentID),
            [first.id]
        )
    }

    func testKeyPhaseActionShortcutRemainsInPluginSettings() throws {
        let plugin = EventHandlingActionBackedShortcutTestPlugin()
        let suiteName = "PluginHostActionRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = makeIsolatedHost(
            plugin: plugin,
            defaults: defaults,
            shortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        )

        XCTAssertTrue(host.shortcutItems.contains {
            $0.id == ActionBackedShortcutTestPlugin.shortcutItemID
        })
        XCTAssertNil(
            host.shortcutAssignmentService.assignment(
                for: ActionReference(key: plugin.definition.key)
            )
        )
    }

    func testAppShortcutEditorKeepsConvergedAssignmentsIndividuallyEditable() throws {
        let suiteName = "PluginHostActionRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reference = ActionReference(
            key: ActionKey(providerID: "mactools", actionID: AppShortcutAction.openSettings.rawValue)
        )
        let first = ActionShortcutAssignmentRecord(
            reference: reference,
            binding: ShortcutBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])
        )
        let second = ActionShortcutAssignmentRecord(
            reference: reference,
            binding: ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            ActionShortcutAssignmentStore(userDefaults: defaults).replaceAll([first, second]),
            .committed
        )
        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()),
            loadDynamicPluginsOnInit: false
        )

        let rows = host.appShortcutItems.filter { $0.action == .openSettings }
        XCTAssertEqual(rows.map(\.assignmentID), [first.id, second.id])

        host.clearAppShortcut(.openSettings, assignmentID: second.id)

        XCTAssertEqual(
            host.shortcutAssignmentService.assignments.filter { $0.reference == reference },
            [first]
        )
    }

    func testMissingProviderShortcutRemainsVisibleUnavailableAndAssigned() throws {
        let suiteName = "PluginHostActionRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let plugin = NativeActionTestPlugin()
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_U),
            modifiers: [.command, .option]
        )
        let firstHost = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(
                userDefaults: defaults
            ),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        )
        let reference = ActionReference(key: plugin.definition.key)
        XCTAssertEqual(firstHost.setActionShortcutBinding(binding, to: reference), .success)

        let reloadedHost = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(
                userDefaults: defaults
            ),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        )
        let item = try XCTUnwrap(
            reloadedHost.actionShortcutCatalogItems.first { $0.reference == reference }
        )

        XCTAssertEqual(item.bindingText, ShortcutFormatter.displayString(for: binding))
        XCTAssertEqual(item.status, .unavailable(FeatureL10n.string("操作不可用。")))
        XCTAssertFalse(item.canAssign)
        XCTAssertEqual(
            reloadedHost.shortcutAssignmentService.assignment(for: reference)?.binding,
            binding
        )
    }

    func testShortcutRunLinkWorkflowAndRuleSurviveIsolatedHostRelaunch() async throws {
        let suiteName = "PluginHostActionRegistryTests.integration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstPlugin = ParameterizedActionTestPlugin()
        let firstManager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let firstHost = makeIsolatedHost(
            plugin: firstPlugin,
            defaults: defaults,
            shortcutManager: firstManager
        )
        let reference = try firstPlugin.reference(target: "display-1")
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_3),
            modifiers: [.control, .command]
        )

        XCTAssertEqual(firstHost.setActionShortcutBinding(binding, to: reference), .success)
        let runLink = try firstHost.createActionRunLink(for: reference).get()
        let workflow = try XCTUnwrap(firstHost.automationController.createWorkflow())
        firstHost.automationController.addStep(workflowID: workflow.id, reference: reference)
        let rule = try XCTUnwrap(
            firstHost.automationController.createRule(workflowID: workflow.id)
        )

        let secondPlugin = ParameterizedActionTestPlugin()
        let secondManager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let secondHost = makeIsolatedHost(
            plugin: secondPlugin,
            defaults: defaults,
            shortcutManager: secondManager
        )

        XCTAssertEqual(
            secondHost.shortcutAssignmentService.assignment(for: reference)?.binding,
            binding
        )
        XCTAssertEqual(
            secondHost.automationController.workflows.first(where: { $0.id == workflow.id })?.steps.map(\.reference),
            [reference]
        )
        XCTAssertEqual(
            secondHost.automationController.rules(workflowID: workflow.id).map(\.id),
            [rule.id]
        )
        guard case let .available(reloadedRunLink, presetID) = secondHost.actionRunLinkPresentation(
            for: reference
        ) else {
            return XCTFail("Expected the Run Link preset to survive relaunch")
        }
        XCTAssertEqual(reloadedRunLink, runLink)
        XCTAssertNotNil(presetID)

        let outcome = await secondHost.actionExecutor.execute(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        )
        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertEqual(secondPlugin.invocations.map(\.reference), [reference])
    }

    private func makeIsolatedHost(
        plugin: any MacToolsPlugin,
        defaults: UserDefaults,
        shortcutManager: GlobalShortcutManager,
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80)
    ) -> PluginHost {
        PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: shortcutManager,
            pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay,
            loadDynamicPluginsOnInit: false,
            actionURLScheme: "mactools-tests"
        )
    }

    private func registrations(
        for reference: ActionReference,
        in host: PluginHost,
        manager: GlobalShortcutManager
    ) -> [GlobalShortcutManager.Registration] {
        guard let binding = host.actionShortcutSettingsItem(for: reference)?.assignment.binding else {
            return []
        }
        return manager.debugRegistrationsForTests.filter {
            $0.binding == binding
        }
    }
}

@MainActor
private final class PreparingActionTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginActionCatalogPreparing
{
    let metadata: PluginMetadata
    let actionKey: ActionKey
    let definition: ActionDefinition
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var isPreparing = false
    private(set) var preparationCount = 0
    private(set) var cancellationCount = 0
    private var isPrepared: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(
        id: String = "preparing-action-provider",
        initiallyPrepared: Bool = false,
        definitionTitle: String = "Prepared Action"
    ) {
        metadata = PluginMetadata(
            id: id,
            title: "Preparing Actions",
            iconName: "clock",
            iconTint: .blue,
            order: 0,
            defaultDescription: "Tests external discovery preparation"
        )
        actionKey = ActionKey(providerID: id, actionID: "prepared")
        definition = ActionDefinition(
            key: actionKey,
            title: definitionTitle,
            description: "Appears after asynchronous preparation.",
            systemImage: "clock",
            externalInvocationPolicy: .allowed,
            capabilities: [.background]
        )
        isPrepared = initiallyPrepared
    }

    var actionDefinitions: [ActionDefinition] { isPrepared ? [definition] : [] }
    var actionCatalogEntries: [ActionCatalogEntry] {
        isPrepared
            ? [ActionCatalogEntry(reference: ActionReference(key: actionKey), title: definition.title)]
            : []
    }

    func prepareActionCatalogForExternalDiscovery() async {
        isPreparing = true
        preparationCount += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuations.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationCount += 1
            }
        }
    }

    func finishPreparation() {
        isPrepared = true
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class InputGestureClaimTestPlugin: MacToolsPlugin, PluginInputGestureClaimProviding {
    let metadata: PluginMetadata
    let activeInputGestureClaims: [PluginInputGestureClaim]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, claims: [PluginInputGestureClaim]) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "hand.tap",
            iconTint: .blue,
            order: 0,
            defaultDescription: id
        )
        activeInputGestureClaims = claims
    }
}

@MainActor
private final class InputGestureConflictTestPlugin: MacToolsPlugin,
    PluginInputGestureConflictConsuming
{
    let metadata = PluginMetadata(
        id: "gesture-consumer",
        title: "Gesture Consumer",
        iconName: "hand.tap",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Gesture Consumer"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var conflicts: [PluginInputGestureConflict] = []

    func inputGestureConflictsDidChange(_ conflicts: [PluginInputGestureConflict]) {
        self.conflicts = conflicts
    }
}

@MainActor
private final class NativeActionTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginActionExposureProviding,
    PluginActionPermissionProviding,
    ActionSurfaceAssignmentSummarizing
{
    let metadata = PluginMetadata(
        id: "action-provider",
        title: "操作插件",
        iconName: "bolt",
        iconTint: .blue,
        order: 1,
        defaultDescription: "测试操作"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var availability: ActionAvailability = .available
    var appIntentExposurePolicy: ActionExposurePolicy = .automatic
    var beginCount = 0
    var summarizedReference: ActionReference?
    var permissionTitles = ["测试权限"]
    var additionalDefinitions: [ActionDefinition] = []
    var operation: @MainActor @Sendable () async -> ActionExecutionResult = {
        .succeeded(message: "native")
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        permissionTitles.enumerated().map { index, title in
            PluginPermissionRequirement(
                id: "test-permission-\(index)",
                kind: .accessibility,
                title: title,
                description: "测试操作所需权限"
            )
        }
    }

    let definition = ActionDefinition(
        key: ActionKey(providerID: "action-provider", actionID: "toggle"),
        title: "切换",
        description: "切换测试状态",
        systemImage: "bolt",
        externalInvocationPolicy: .allowed,
        capabilities: [.background, .foregroundInteractive]
    )

    var actionDefinitions: [ActionDefinition] {
        [definition] + additionalDefinitions
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        availability
    }

    func exposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        surface == .appIntents ? appIntentExposurePolicy : .automatic
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        beginCount += 1
        return ActionExecutionHandle(operation: operation)
    }

    func actionSurfaceAssignmentSummary(
        for reference: ActionReference
    ) -> ActionSurfaceAssignmentSummary? {
        guard reference == summarizedReference else { return nil }
        return ActionSurfaceAssignmentSummary(
            surfaceID: metadata.id,
            surfaceTitle: metadata.title,
            systemImage: metadata.iconName,
            detail: "已分配"
        )
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        actionKey == definition.key
            ? permissionTitles.indices.map { "test-permission-\($0)" }
            : []
    }
}

@MainActor
private final class RuntimeLocalizedActionTestPlugin: MacToolsPlugin, PluginActionProviding {
    static let providerID = "runtime-localized-action"

    let metadata = PluginMetadata(
        id: providerID,
        title: "Stale Construction Title",
        iconName: "globe",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Stale construction description"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionKey: ActionKey { ActionKey(providerID: Self.providerID, actionID: "toggle") }

    var actionDefinitions: [ActionDefinition] {
        let isArabic = PluginRuntimeLocalization.locale.language.languageCode?.identifier == "ar"
        return [
            ActionDefinition(
                key: actionKey,
                title: isArabic ? "تبديل" : "Toggle",
                description: isArabic ? "بدّل حالة اختبار." : "Switch a test state.",
                systemImage: "globe",
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class PluginHostDynamicTestLoader: DynamicPluginLoading {
    let plugin: any MacToolsPlugin
    private(set) var loadCount = 0

    init(plugin: any MacToolsPlugin) {
        self.plugin = plugin
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        loadCount += 1
        return records.map {
            DynamicPluginLoadResult(record: $0, plugins: [plugin], errorMessage: nil)
        }
    }
}

@MainActor
private final class LegacyActionTestPlugin: MacToolsPlugin, PluginCommandProviding {
    let metadata = PluginMetadata(
        id: "legacy-provider",
        title: "旧操作插件",
        iconName: "moon",
        iconTint: .gray,
        order: 2,
        defaultDescription: "测试旧操作"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var performedCommandIDs: [String] = []

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "sleep",
                title: "休眠",
                description: "立即休眠",
                systemImage: "moon"
            ),
        ]
    }

    func handleCommand(id: String) {
        performedCommandIDs.append(id)
    }
}

@MainActor
private final class ParameterizedActionTestPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "parameterized-action-provider",
        title: "Parameterized Actions",
        iconName: "slider.horizontal.3",
        iconTint: .blue,
        order: 4,
        defaultDescription: "Integration test actions"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var invocations: [ActionInvocation] = []
    var targets = ["display-1"]

    let definition = ActionDefinition(
        key: ActionKey(providerID: "parameterized-action-provider", actionID: "select"),
        title: "Select Target",
        description: "Select a deterministic test target.",
        systemImage: "scope",
        parameters: [
            ActionParameterDefinition(id: "target", title: "Target", kind: .string),
        ],
        externalInvocationPolicy: .allowed,
        capabilities: [.foregroundInteractive]
    )

    var actionDefinitions: [ActionDefinition] { [definition] }

    var actionCatalogEntries: [ActionCatalogEntry] {
        targets.map { target in
            ActionCatalogEntry(
                reference: try! reference(target: target),
                title: definition.title,
                subtitle: metadata.title
            )
        }
    }

    func reference(target: String) throws -> ActionReference {
        ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["target": .string(target)])
        )
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        invocations.append(invocation)
        return ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private class ActionBackedShortcutTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginLegacyActionShortcutProviding
{
    static let shortcutItemID = "action-backed-shortcut.shortcut.toggle"

    let metadata = PluginMetadata(
        id: "action-backed-shortcut",
        title: "共享快捷键",
        iconName: "command",
        iconTint: .blue,
        order: 3,
        defaultDescription: "测试共享快捷键"
    )
    let defaultBinding = ShortcutBinding(
        keyCode: UInt16(kVK_ANSI_M),
        modifiers: [.command, .option]
    )
    let definition = ActionDefinition(
        key: ActionKey(providerID: "action-backed-shortcut", actionID: "toggle"),
        title: "切换",
        description: "切换测试状态",
        systemImage: "command",
        externalInvocationPolicy: .allowed,
        capabilities: [.foregroundInteractive]
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: "toggle",
                title: "切换",
                description: "切换测试状态",
                actionID: definition.key.actionID,
                scope: .global,
                defaultBinding: defaultBinding,
                isRequired: false
            ),
        ]
    }

    var actionDefinitions: [ActionDefinition] { [definition] }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        guard let binding = shortcutBindingResolver?("toggle") else { return [] }
        return [
            LegacyActionShortcutAssignment(
                reference: ActionReference(key: definition.key),
                binding: binding,
                legacyShortcutDefinitionID: "toggle"
            ),
        ]
    }

    func legacyActionShortcutsDidMigrate() {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class EventHandlingActionBackedShortcutTestPlugin:
    ActionBackedShortcutTestPlugin,
    PluginShortcutEventHandling
{
    override var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] { [] }

    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {}
}

@MainActor
private final class SafetyStateActionTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginActionSafetyStateChangeProviding
{
    let metadata = PluginMetadata(
        id: "safety-state-action-provider",
        title: "安全状态操作插件",
        iconName: "lock.shield",
        iconTint: .blue,
        order: 1,
        defaultDescription: "测试同步安全状态"
     )
    var onStateChange: (() -> Void)?
    var onActionSafetyStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requiresConfirmation = false
    var allowsRunLink = true
    var beginCount = 0

    var actionKey: ActionKey {
        ActionKey(providerID: metadata.id, actionID: "run")
     }

    var actionDefinitions: [ActionDefinition] {
         [
            ActionDefinition(
                key: actionKey,
                title: "运行",
                description: "运行测试操作",
                systemImage: "lock.shield",
                risk: requiresConfirmation ? .confirmationRequired : .safe,
                confirmation: ActionConfirmation(
                    title: "运行？",
                    message: "运行测试操作。",
                    confirmButtonTitle: "运行"
                 ),
                externalInvocationPolicy: allowsRunLink ? .confirmAlways : .unavailable,
                capabilities: [.background]
             ),
         ]
     }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        beginCount += 1
        return ActionExecutionHandle { .succeeded() }
     }
}
