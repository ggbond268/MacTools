import XCTest
import MacToolsPluginKit
@testable import FanControlPlugin

@MainActor
final class FanControlPluginTests: XCTestCase {
    func testMetadataAndInitialPanelState() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "fan-control")
        XCTAssertEqual(plugin.metadata.title, "风扇控制")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .disclosure)
        XCTAssertFalse(plugin.primaryPanelState.isExpanded)
        XCTAssertTrue(plugin.primaryPanelState.subtitle.contains("自动"))
    }

    func testRefreshShowsFanSpeedInSubtitle() {
        let plugin = makePlugin(reader: MockSMCReader(snapshot: FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3600],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45
        )))

        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.subtitle.contains("3600 RPM"))
    }

    func testSelectingBuiltInPresetAppliesStrategy() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))

        XCTAssertEqual(writer.appliedStrategy, .fullSpeed)
    }

    func testSliderEndedUpdatesCustomPresetRPM() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        let preset = plugin.presetStore.addCustomPreset()!
        plugin.presetStore.setActivePreset(id: preset.id)

        plugin.handleAction(.setSlider(controlID: "fan-custom-rpm", value: 4000, phase: .ended))

        XCTAssertEqual(writer.appliedStrategy, .fixed(rpm: 4000))
    }

    func testWriteErrorAppearsAndCollapseClearsIt() {
        let writer = MockSMCWriter()
        writer.writeError = .writeFailed("硬件写入失败")
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setDisclosureExpanded(true))
        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)

        plugin.handleAction(.setDisclosureExpanded(false))
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testDisclosureNoOpDoesNotNotifyStateChange() {
        let plugin = makePlugin()
        var stateChangeCount = 0
        plugin.onStateChange = {
            stateChangeCount += 1
        }

        plugin.handleAction(.setDisclosureExpanded(false))

        XCTAssertEqual(stateChangeCount, 0)
    }

    func testDeletingActiveCustomPresetResetsToAuto() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        let preset = plugin.presetStore.addCustomPreset()!
        plugin.presetStore.setActivePreset(id: preset.id)

        plugin.handleAction(.invokeAction(controlID: "fan-delete-preset"))

        XCTAssertEqual(writer.appliedStrategy, .auto)
    }

    func testDeactivateWithoutSuccessfulManualPresetDoesNotRestoreAuto() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)

        plugin.deactivate(reason: .hostShutdown)

        XCTAssertTrue(writer.appliedStrategies.isEmpty)
    }

    func testDeactivateAfterSuccessfulManualPresetRestoresAuto() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.appliedStrategies, [.fullSpeed, .auto])
    }

    func testDeactivateAfterHelperInstallFailureDoesNotRestoreAuto() {
        let writer = MockSMCWriter()
        writer.writeError = .helperInstallFailed("用户取消了授权")
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.appliedStrategies, [.fullSpeed])
    }

    func testDeactivateAfterManualPresetSkipsRestoreWhenInstalledHelperIsUnavailable() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        writer.isInstalledHelperAvailable = false
        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.appliedStrategies, [.fullSpeed])
    }

    func testSelectingAutoClearsDeactivateRestoreRequirement() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.auto))
        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.appliedStrategies, [.fullSpeed, .auto])
    }

    func testCanonicalActionsPublishAndApplyEveryFanPreset() async throws {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        let custom = plugin.presetStore.addCustomPreset()!
        plugin.presetStore.updateCustomPresetRPM(id: custom.id, rpm: 3800)

        XCTAssertEqual(plugin.actionCatalogEntries.count, 3)
        let customReference = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: { $0.title.contains(custom.name) })?.reference
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: customReference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(plugin.presetStore.activePresetID, custom.id)
        XCTAssertEqual(writer.appliedStrategy, .fixed(rpm: 3800))
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
    }

    func testCanonicalPresetDefersMutationUntilHandleStarts() async throws {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        let fullSpeed = try XCTUnwrap(plugin.actionCatalogEntries.first(where: {
            $0.reference.parameters["preset"] == .string(FanPresetBuiltInID.fullSpeed)
        })?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: fullSpeed,
            source: .test,
            mode: .background
        ))

        XCTAssertEqual(plugin.presetStore.activePresetID, FanPresetBuiltInID.auto)
        XCTAssertTrue(writer.appliedStrategies.isEmpty)
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(plugin.presetStore.activePresetID, FanPresetBuiltInID.fullSpeed)
        XCTAssertEqual(writer.appliedStrategies, [.fullSpeed])
    }

    func testCanonicalPresetWriteFailureRestoresPreviousHardwareAndPreferences() async throws {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        plugin.handleAction(.setSelection(
            controlID: "fan-preset-list",
            optionID: FanPresetBuiltInID.fullSpeed
        ))
        writer.queuedWriteErrors = [.writeFailed("target failed"), nil]
        let automatic = try XCTUnwrap(plugin.actionCatalogEntries.first(where: {
            $0.reference.parameters["preset"] == .string(FanPresetBuiltInID.auto)
        })?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: automatic,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected preset failure, got \(result)")
        }
        XCTAssertEqual(plugin.presetStore.activePresetID, FanPresetBuiltInID.fullSpeed)
        XCTAssertEqual(writer.appliedStrategies.suffix(2), [.auto, .fullSpeed])
    }

    func testCanonicalPresetPersistenceFailureRestoresPreviousHardwareAndPreferences() async throws {
        let storage = FanControlMemoryStorage()
        let writer = MockSMCWriter()
        let plugin = makePlugin(storage: storage, writer: writer)
        plugin.handleAction(.setSelection(
            controlID: "fan-preset-list",
            optionID: FanPresetBuiltInID.fullSpeed
        ))
        storage.blockedSetKeys = ["active-preset-id"]
        let automatic = try XCTUnwrap(plugin.actionCatalogEntries.first(where: {
            $0.reference.parameters["preset"] == .string(FanPresetBuiltInID.auto)
        })?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: automatic,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        XCTAssertEqual(plugin.presetStore.activePresetID, FanPresetBuiltInID.fullSpeed)
        XCTAssertEqual(writer.appliedStrategies.suffix(2), [.auto, .fullSpeed])
        storage.blockedSetKeys = []
        XCTAssertEqual(
            makePlugin(storage: storage).presetStore.activePresetID,
            FanPresetBuiltInID.fullSpeed
        )
    }

    func testDeletedCustomPresetActionBecomesUnavailable() throws {
        let plugin = makePlugin()
        let custom = plugin.presetStore.addCustomPreset()!
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: { $0.title.contains(custom.name) })?.reference
        )

        plugin.presetStore.deleteCustomPreset(id: custom.id)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    func testPresetCatalogChangesNotifyTheHost() {
        let plugin = makePlugin()
        var notifications = 0
        plugin.onStateChange = { notifications += 1 }

        let preset = plugin.presetStore.addCustomPreset()!
        plugin.presetStore.renameCustomPreset(id: preset.id, newName: "Quiet")
        plugin.presetStore.deleteCustomPreset(id: preset.id)

        XCTAssertEqual(notifications, 3)
    }

    func testPortablePresetMutationsEmitPersistentPreferenceSignal() throws {
        let plugin = makePlugin()
        var notifications = 0
        plugin.onPersistentPreferencesChange = { notifications += 1 }
        let preset = try XCTUnwrap(plugin.presetStore.addCustomPreset())

        XCTAssertTrue(plugin.presetStore.setActivePreset(id: preset.id))
        XCTAssertTrue(plugin.presetStore.updateCustomPresetRPM(id: preset.id, rpm: 3_800))

        XCTAssertEqual(notifications, 3)
    }

    func testIdenticalPresetMutationsAndRestoreDoNotEmitPersistentPreferenceSignal() throws {
        let plugin = makePlugin()
        let preset = try XCTUnwrap(plugin.presetStore.addCustomPreset())
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        var notifications = 0
        plugin.onPersistentPreferencesChange = { notifications += 1 }
        notifications = 0

        XCTAssertTrue(plugin.presetStore.setActivePreset(id: FanPresetBuiltInID.auto))
        XCTAssertTrue(plugin.presetStore.updateCustomPresetRPM(
            id: preset.id,
            rpm: FanRPMLimits.absoluteMin
        ))
        XCTAssertTrue(plugin.presetStore.renameCustomPreset(id: preset.id, newName: preset.name))
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))

        XCTAssertEqual(notifications, 0)
    }

    func testPresetMutationsPublishOnlyAfterDurablePersistence() throws {
        let storage = FanControlMemoryStorage()
        let plugin = makePlugin(storage: storage)
        let preset = try XCTUnwrap(plugin.presetStore.addCustomPreset())
        XCTAssertTrue(plugin.presetStore.setActivePreset(id: preset.id))
        var notifications = 0
        plugin.onStateChange = { notifications += 1 }
        storage.blockedSetKeys = ["custom-presets"]

        XCTAssertFalse(plugin.presetStore.renameCustomPreset(id: preset.id, newName: "Quiet"))
        XCTAssertFalse(plugin.presetStore.deleteCustomPreset(id: preset.id))

        XCTAssertEqual(plugin.presetStore.customPresets.first?.name, preset.name)
        XCTAssertEqual(plugin.presetStore.activePresetID, preset.id)
        XCTAssertEqual(notifications, 0)
        storage.blockedSetKeys = []
        let reloaded = makePlugin(storage: storage)
        XCTAssertEqual(reloaded.presetStore.customPresets.first?.name, preset.name)
        XCTAssertEqual(reloaded.presetStore.activePresetID, preset.id)
    }

    func testActivePresetDeletionPersistenceFailureDoesNotApplyAutomaticPolicy() throws {
        let storage = FanControlMemoryStorage()
        let writer = MockSMCWriter()
        let plugin = makePlugin(storage: storage, writer: writer)
        let preset = try XCTUnwrap(plugin.presetStore.addCustomPreset())
        XCTAssertTrue(plugin.presetStore.setActivePreset(id: preset.id))
        storage.blockedSetKeys = ["active-preset-id"]
        let appliedCount = writer.appliedStrategies.count

        plugin.handleAction(.invokeAction(controlID: "fan-delete-preset"))

        XCTAssertEqual(plugin.presetStore.activePresetID, preset.id)
        XCTAssertEqual(writer.appliedStrategies.count, appliedCount)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        storage.blockedSetKeys = []
        let reloaded = makePlugin(storage: storage)
        XCTAssertEqual(reloaded.presetStore.activePresetID, preset.id)
        XCTAssertEqual(reloaded.presetStore.customPresets.map(\.id), [preset.id])
    }

    func testPortablePreferencesPreserveCustomPresetActionIdentifiers() throws {
        let source = makePlugin()
        let preset = source.presetStore.addCustomPreset()!
        source.presetStore.renameCustomPreset(id: preset.id, newName: "Quiet")
        source.presetStore.updateCustomPresetRPM(id: preset.id, rpm: 3_800)
        source.presetStore.setActivePreset(id: preset.id)
        let reference = try XCTUnwrap(
            source.actionCatalogEntries.first(where: { $0.reference.parameters["preset"] == .string(preset.id) })?.reference
        )
        let backup = try XCTUnwrap(source.makePortablePreferencesBackup())

        let restored = makePlugin()
        restored.restorePortablePreferences(from: backup)

        XCTAssertEqual(restored.presetStore.activePresetID, preset.id)
        XCTAssertTrue(restored.actionCatalogEntries.contains(where: { $0.reference == reference }))
        XCTAssertTrue(restored.actionAvailability(for: reference).isAvailable)
    }

    func testPortablePreferencesRoundTripAtUserInputLimits() throws {
        let source = makePlugin()
        for _ in 0..<100 {
            XCTAssertNotNil(source.presetStore.addCustomPreset())
        }
        XCTAssertFalse(source.presetStore.canAddPreset)
        XCTAssertNil(source.presetStore.addCustomPreset())
        let first = try XCTUnwrap(source.presetStore.customPresets.first)
        source.presetStore.renameCustomPreset(
            id: first.id,
            newName: String(repeating: "A", count: 150)
        )
        XCTAssertEqual(source.presetStore.customPresets.first?.name.count, 100)

        let backup = try XCTUnwrap(source.makePortablePreferencesBackup())
        let restored = makePlugin()
        restored.restorePortablePreferences(from: backup)

        XCTAssertEqual(restored.presetStore.customPresets.count, 100)
        XCTAssertEqual(restored.presetStore.customPresets.first?.name.count, 100)
    }

    func testActiveRestoreAppliesManualAndAutomaticStrategiesToHardware() throws {
        let manualSource = makePlugin()
        manualSource.presetStore.setActivePreset(id: FanPresetBuiltInID.fullSpeed)
        let manualBackup = try XCTUnwrap(manualSource.makePortablePreferencesBackup())
        let autoBackup = try XCTUnwrap(makePlugin().makePortablePreferencesBackup())

        let writer = MockSMCWriter()
        let restored = makePlugin(writer: writer)
        restored.activate(context: PluginRuntimeContext(pluginID: "fan-control"))

        XCTAssertTrue(restored.restorePortablePreferencesReportingResult(from: manualBackup))
        XCTAssertEqual(writer.appliedStrategies.last, .fullSpeed)
        XCTAssertTrue(restored.restorePortablePreferencesReportingResult(from: autoBackup))
        XCTAssertEqual(writer.appliedStrategies.last, .auto)

        restored.deactivate(reason: .hostShutdown)
    }

    func testFailedActiveRestoreRollsBackPreferencesAndHardwareStrategy() throws {
        let autoBackup = try XCTUnwrap(makePlugin().makePortablePreferencesBackup())
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        plugin.activate(context: PluginRuntimeContext(pluginID: "fan-control"))
        plugin.handleAction(.setSelection(
            controlID: "fan-preset-list",
            optionID: FanPresetBuiltInID.fullSpeed
        ))
        writer.queuedWriteErrors = [.writeFailed("restore failed"), nil]

        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: autoBackup))
        XCTAssertEqual(plugin.presetStore.activePresetID, FanPresetBuiltInID.fullSpeed)
        XCTAssertEqual(writer.appliedStrategies.suffix(2), [.auto, .fullSpeed])
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)

        plugin.deactivate(reason: .hostShutdown)
    }

    func testPortableRestoreWriteFailureRollsBackEveryStoredValue() throws {
        let source = makePlugin()
        let preset = try XCTUnwrap(source.presetStore.addCustomPreset())
        source.presetStore.setActivePreset(id: preset.id)
        let backup = try XCTUnwrap(source.makePortablePreferencesBackup())
        let storage = FanControlMemoryStorage()
        let destination = makePlugin(storage: storage)
        destination.presetStore.setActivePreset(id: FanPresetBuiltInID.fullSpeed)
        storage.blockedSetKeys = ["active-preset-id"]

        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: backup))
        storage.blockedSetKeys = []
        let reloaded = makePlugin(storage: storage)
        XCTAssertTrue(reloaded.presetStore.customPresets.isEmpty)
        XCTAssertEqual(reloaded.presetStore.activePresetID, FanPresetBuiltInID.fullSpeed)
    }

    func testPortableRestoreRejectsWrongTypedRawPresetWithoutRemovingIt() throws {
        let source = makePlugin()
        _ = try XCTUnwrap(source.presetStore.addCustomPreset())
        let backup = try XCTUnwrap(source.makePortablePreferencesBackup())
        let storage = FanControlMemoryStorage()
        storage.setRawValue("sentinel", forKey: "custom-presets")
        let destination = makePlugin(storage: storage)

        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(storage.rawValue(forKey: "custom-presets") as? String, "sentinel")
    }

    func testCustomPresetActionsDependOnPortablePreferencesButBuiltInsDoNot() throws {
        let plugin = makePlugin()
        let custom = plugin.presetStore.addCustomPreset()!
        let builtInReference = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: {
                $0.reference.parameters["preset"] == .string(FanPresetBuiltInID.auto)
            })?.reference
        )
        let customReference = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: {
                $0.reference.parameters["preset"] == .string(custom.id)
            })?.reference
        )

        XCTAssertEqual(plugin.backupDisposition(for: builtInReference), .selfContained)
        XCTAssertEqual(
            plugin.backupDisposition(for: customReference),
            .requiresPluginPreferences
        )
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        XCTAssertEqual(
            plugin.actionReferences(inPortablePreferences: backup),
            [customReference]
        )
        XCTAssertNil(plugin.actionReferences(inPortablePreferences: Data("invalid".utf8)))
    }

    func testMonitoringOnlyPublishesMeaningfulSnapshotChanges() async throws {
        let firstSnapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3600],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45
        )
        let equivalentSnapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3605],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45.2
        )
        let changedSnapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3900],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 49
        )
        let reader = MockSMCReader(
            snapshot: changedSnapshot,
            snapshots: [firstSnapshot, equivalentSnapshot, changedSnapshot]
        )
        let plugin = makePlugin(
            reader: reader,
            monitoringActiveInterval: .milliseconds(10),
            monitoringIdleInterval: .milliseconds(10)
        )
        var stateChangeCount = 0
        plugin.onStateChange = {
            stateChangeCount += 1
        }

        plugin.activate(context: PluginRuntimeContext(pluginID: "fan-control"))
        try await Task.sleep(for: .milliseconds(45))
        plugin.deactivate(reason: .disabled)

        XCTAssertGreaterThanOrEqual(reader.readCount, 3)
        XCTAssertEqual(stateChangeCount, 2)
    }

    func testPanelVisibilityAndDisclosureControlActiveMonitoring() async throws {
        let snapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3600],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45
        )
        let reader = MockSMCReader(snapshot: snapshot)
        let plugin = makePlugin(
            reader: reader,
            monitoringActiveInterval: .milliseconds(10),
            monitoringIdleInterval: .milliseconds(200)
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "fan-control"))
        try await Task.sleep(for: .milliseconds(40))
        let idleReadCount = reader.readCount

        plugin.handleAction(.setDisclosureExpanded(true))
        try await Task.sleep(for: .milliseconds(45))
        let expandedWhileHiddenReadCount = reader.readCount

        plugin.panelSurfaceDidBecomeVisible(.primary)
        try await Task.sleep(for: .milliseconds(45))
        let visibleReadCount = reader.readCount

        plugin.panelSurfaceDidBecomeHidden(.primary)
        try await Task.sleep(for: .milliseconds(45))
        let hiddenReadCount = reader.readCount

        plugin.deactivate(reason: .disabled)

        XCTAssertLessThanOrEqual(idleReadCount, 2)
        XCTAssertLessThanOrEqual(expandedWhileHiddenReadCount - idleReadCount, 2)
        XCTAssertGreaterThanOrEqual(visibleReadCount - expandedWhileHiddenReadCount, 3)
        XCTAssertLessThanOrEqual(hiddenReadCount - visibleReadCount, 2)
    }

    private func makePlugin(
        storage: FanControlMemoryStorage? = nil,
        reader: MockSMCReader? = nil,
        writer: MockSMCWriter? = nil,
        monitoringActiveInterval: Duration = .seconds(2),
        monitoringIdleInterval: Duration = .seconds(10)
    ) -> FanControlPlugin {
        FanControlPlugin(
            context: PluginRuntimeContext(
                pluginID: "fan-control",
                storage: storage ?? FanControlMemoryStorage()
            ),
            smcReader: reader ?? MockSMCReader(),
            smcWriter: writer ?? MockSMCWriter(),
            monitoringActiveInterval: monitoringActiveInterval,
            monitoringIdleInterval: monitoringIdleInterval
        )
    }
}

@MainActor
private final class MockSMCReader: FanControlSMCReading {
    var snapshot: FanSnapshot
    var snapshots: [FanSnapshot]
    private(set) var readCount = 0

    init(snapshot: FanSnapshot = .empty, snapshots: [FanSnapshot] = []) {
        self.snapshot = snapshot
        self.snapshots = snapshots
    }

    func readSnapshot() -> FanSnapshot {
        readCount += 1
        guard !snapshots.isEmpty else {
            return snapshot
        }
        return snapshots.removeFirst()
    }
}

@MainActor
private final class MockSMCWriter: FanControlSMCWriting {
    var isHelperAvailable = true
    var isInstalledHelperAvailable = true
    var appliedStrategy: FanControlStrategy?
    var appliedStrategies: [FanControlStrategy] = []
    var writeError: FanWriteError?
    var queuedWriteErrors: [FanWriteError?] = []

    func apply(strategy: FanControlStrategy, snapshot _: FanSnapshot) -> FanWriteError? {
        appliedStrategy = strategy
        appliedStrategies.append(strategy)
        if !queuedWriteErrors.isEmpty {
            return queuedWriteErrors.removeFirst()
        }
        return writeError
    }
}

@MainActor
private final class FanControlMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }

    func setRawValue(_ value: Any, forKey key: String) {
        values[key] = value
    }

    func rawValue(forKey key: String) -> Any? {
        values[key]
    }
}
