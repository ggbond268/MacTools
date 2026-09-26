import Combine
import MacToolsPluginKit
import XCTest
@testable import AIAssistantPlugin
@testable import MacTools

@MainActor
final class PluginHostShortcutUpdateTests: XCTestCase {
    func testAIAssistantSwitchesReleaseAndRestoreGlobalRegistrations() async {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = AIAssistantPlugin(context: PluginRuntimeContext(
            pluginID: "ai-assistant", storage: storage
        ))
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let host = makePluginHostForTests(plugins: [plugin], globalShortcutManager: manager)
        let shortcutIDs = Set(plugin.shortcutDefinitions.map { "ai-assistant.shortcut.\($0.id)" })
        func registeredIDs() -> Set<String> {
            Set(manager.registrationStatuses.keys).intersection(shortcutIDs)
        }
        XCTAssertEqual(registeredIDs(), shortcutIDs)

        var prompts = AIAssistantPromptStore(storage: storage).loadPrompts()
        prompts[1].isEnabled = false
        XCTAssertNil(plugin.savePromptsConfiguration(prompts))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(registeredIDs().count, 2)
        XCTAssertFalse(registeredIDs().contains("ai-assistant.shortcut.ai-assistant.prompt.summarize"))

        plugin.handleAction(.setSwitch(false))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertTrue(registeredIDs().isEmpty)
        XCTAssertEqual(plugin.shortcutDefinitions.count, 3)
        let custom = ShortcutBinding(keyCode: 18, modifiers: [.control, .option, .command])
        let summaryID = "ai-assistant.shortcut.ai-assistant.prompt.summarize"
        XCTAssertNil(host.setShortcutBindingAndReturnError(custom, for: summaryID))
        XCTAssertEqual(plugin.shortcutBindingResolver?("ai-assistant.prompt.summarize"), custom)
        XCTAssertFalse(registrar.registeredBindings.contains(custom))

        plugin.handleAction(.setSwitch(true))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(registeredIDs().count, 2)
        XCTAssertFalse(registrar.registeredBindings.contains(custom))
        host.clearShortcut(for: summaryID)
        XCTAssertNil(plugin.shortcutBindingResolver?("ai-assistant.prompt.summarize"))
        XCTAssertNil(host.setShortcutBindingAndReturnError(custom, for: summaryID))

        prompts[1].isEnabled = true
        XCTAssertNil(plugin.savePromptsConfiguration(prompts))
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(registeredIDs(), shortcutIDs)
        XCTAssertTrue(registrar.registeredBindings.contains(custom))
    }

    func testCombinedUpdateProjectsAvailabilityOnceAndReusesShortcutDefinitions() async {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.availabilityReads = 0
        plugin.definitionReads = 0
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(plugin.availabilityReads, 1)
        XCTAssertEqual(plugin.definitionReads, 2)
        XCTAssertEqual(host.actionShortcutCatalogItems.first { $0.reference == plugin.reference }?.status, .unassigned)
    }

    func testShortcutResolverReadsLiveDefinitionsOutsidePresentation() {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.defaultBinding = nil
        XCTAssertNil(plugin.shortcutBindingResolver?("exit"))
        XCTAssertEqual(host.actionAvailability(for: plugin.reference), .unavailable("Exit shortcut required"))
    }

    func testReentrantStateChangeInvalidatesPresentationShortcutSnapshot() async {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.beforeAvailability = { [weak plugin] in
            plugin?.beforeAvailability = nil
            plugin?.defaultBinding = nil
            plugin?.onStateChange?()
        }
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(host.actionShortcutCatalogItems.first { $0.reference == plugin.reference }?.status,
                       .unavailable("Exit shortcut required"))
        await host.waitForScheduledPluginStateRebuildForTests()
    }

    func testCatalogConsumerSeesFreshRegistryAndItsShortcutChangesReachPresentation() async {
        let plugin = AvailabilityShortcutPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.actionTitle = "Updated action"
        plugin.onCatalogChange = { [weak plugin] in
            guard let plugin else { return }
            XCTAssertEqual(plugin.actionExecutionHostContext?.item(for: plugin.reference)?.title, "Updated action")
            plugin.defaultBinding = nil
        }
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()

        XCTAssertEqual(host.actionShortcutCatalogItems.first { $0.reference == plugin.reference }?.status,
                       .unavailable("Exit shortcut required"))
        XCTAssertNil(plugin.shortcutBindingResolver?("exit"))
    }

    func testPhaseShortcutsReadDefinitionsOncePerHostPhase() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.definitionReads = 0
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.definitionReads, 2, "Rebuild and registration each read one fresh snapshot")
        XCTAssertEqual(host.shortcutItems.filter { $0.pluginID == plugin.metadata.id }.count, 16)
    }

    func testUnchangedStateDoesNotRedeliverPhaseBindings() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        XCTAssertEqual(plugin.deliveries.count, 16, "Each initial nil must be delivered")
        plugin.deliveries.removeAll()
        var catalogPublications = 0
        let observation = host.$actionShortcutCatalogItems.dropFirst().sink { _ in catalogPublications += 1 }
        for _ in 0..<20 { plugin.onStateChange?() }
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertTrue(plugin.deliveries.isEmpty)
        XCTAssertEqual(catalogPublications, 0)
        withExtendedLifetime(observation) {}
    }

    func testDynamicDefaultChangeAndClearStillNotifyListener() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.deliveries.removeAll()
        let binding = ShortcutBinding(keyCode: 3, modifiers: [.command, .option, .control])
        plugin.defaultBinding = binding
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.deliveries.map(\.id), ["0"])
        XCTAssertEqual(plugin.deliveries.first?.binding, binding)
        plugin.deliveries.removeAll()
        plugin.defaultBinding = nil
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.deliveries.map(\.id), ["0"])
        XCTAssertNil(plugin.deliveries.first?.binding)
    }

    func testReappearingShortcutReceivesInitialNilAgain() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.deliveries.removeAll()
        plugin.includesFirstShortcut = false
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        plugin.includesFirstShortcut = true
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(plugin.deliveries.map(\.id), ["0"])
        XCTAssertNil(plugin.deliveries.first?.binding)
    }

    func testCompletedMigrationDoesNotReadLegacyPayloadOnStateUpdates() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        XCTAssertEqual(plugin.migrationReads, 1)
        XCTAssertEqual(plugin.migrationCompletions, 1)
        for _ in 0..<3 {
            plugin.onStateChange?()
            await host.waitForScheduledPluginStateRebuildForTests()
        }
        XCTAssertEqual(plugin.migrationReads, 1)
        XCTAssertEqual(plugin.migrationCompletions, 1)
    }

    func testFailedLegacyPayloadReadDoesNotMarkMigrationComplete() {
        let suite = "PluginHostShortcutUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        plugin.failsMigrationRead = true
        let host = makePluginHostForTests(plugins: [plugin], suiteName: suite)
        XCTAssertFalse(ActionShortcutAssignmentStore(userDefaults: defaults)
            .hasMigratedLegacyPluginAssignments(pluginID: plugin.metadata.id))
        XCTAssertEqual(plugin.migrationCompletions, 0)
        XCTAssertNil(plugin.onStateChange, "A failed getter must still isolate the plugin")
        withExtendedLifetime(host) {}
    }

    func testBatchResetUnregistersEveryBindingBeforeReturningAndPublishesOnce() {
        let plugin = ShortcutPlugin(scope: .global)
        let suite = "PluginHostShortcutUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(userDefaults: defaults)
        let bindings = (0..<16).map { ShortcutBinding(keyCode: UInt16($0), modifiers: [.command, .option, .control]) }
        for (index, binding) in bindings.enumerated() {
            store.setCustomization(.custom(binding), for: "batch.shortcut.\(index)")
        }
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let host = PluginHost(plugins: [plugin], shortcutStore: store,
                              pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
                              preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                              globalShortcutManager: manager)
        XCTAssertTrue(Set(bindings).isSubset(of: Set(registrar.registeredBindings)))
        var publications = 0
        let unregisteredBeforeReset = registrar.unregisteredCount
        let subscription = host.menuBarPanelContentDidChange.sink { publications += 1 }
        plugin.resetShortcutCustomizations?((0..<16).map(String.init) + ["unknown", "0"])
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(registrar.unregisteredCount - unregisteredBeforeReset, 16)
        XCTAssertFalse(manager.registrationStatuses.keys.contains { $0.hasPrefix("batch.shortcut.") })
        for index in 0..<16 {
            XCTAssertEqual(store.customization(for: "batch.shortcut.\(index)"), .inheritDefault)
        }
        withExtendedLifetime(subscription) {}
    }
}

@MainActor
private final class AvailabilityShortcutPlugin: MacToolsPlugin, PluginActionProviding,
    PluginActionExecutionHostContextConsuming {
    let metadata = PluginMetadata(id: "availability-shortcut", title: "Availability", iconName: "keyboard",
                                  iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionExecutionHostContext: PluginActionExecutionHostContext?
    var defaultBinding: ShortcutBinding? = ShortcutBinding(keyCode: 3, modifiers: [.command, .option, .control])
    var actionTitle = "Action"
    var definitionReads = 0
    var availabilityReads = 0
    var beforeAvailability: (() -> Void)?
    var onCatalogChange: (() -> Void)?
    var reference: ActionReference { ActionReference(key: ActionKey(providerID: metadata.id, actionID: "enter")) }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        definitionReads += 1
        return [PluginShortcutDefinition(id: "exit", title: "Exit", description: "", actionID: "exit",
                                         scope: .whilePluginActive, defaultBinding: defaultBinding, isRequired: true)]
    }
    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(key: reference.key, title: actionTitle, description: "", systemImage: "keyboard",
                          externalInvocationPolicy: .allowed, capabilities: [.background])]
    }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        availabilityReads += 1
        beforeAvailability?()
        return shortcutBindingResolver?("exit") == nil ? .unavailable("Exit shortcut required") : .available
    }
    func actionExecutionCatalogDidChange() { onCatalogChange?() }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class ShortcutPlugin: MacToolsPlugin, PluginShortcutEventHandling, PluginShortcutResetRequesting,
    PluginShortcutBindingChangeHandling, PluginLegacyActionShortcutProviding {
    struct Delivery {
        let id: String
        let binding: ShortcutBinding?
    }
    let metadata = PluginMetadata(id: "batch", title: "Batch", iconName: "keyboard", iconTint: .blue,
                                  order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var resetShortcutCustomizations: (([String]) -> Void)?
    var definitionReads = 0
    var defaultBinding: ShortcutBinding?
    var includesFirstShortcut = true
    var deliveries: [Delivery] = []
    var migrationReads = 0
    var migrationCompletions = 0
    var failsMigrationRead = false
    let scope: ShortcutScope
    init(scope: ShortcutScope) { self.scope = scope }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        definitionReads += 1
        return (includesFirstShortcut ? 0..<16 : 1..<16).map {
            PluginShortcutDefinition(id: String($0), title: "Shortcut \($0)", description: "", actionID: String($0),
                                     scope: scope, defaultBinding: $0 == 0 ? defaultBinding : nil, isRequired: false)
        }
    }
    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        migrationReads += 1
        if failsMigrationRead { raiseTestPluginException(reason: "Legacy payload unavailable") }
        return []
    }
    func legacyActionShortcutsDidMigrate() { migrationCompletions += 1 }
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        deliveries.append(Delivery(id: id, binding: binding))
    }
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {}
}
