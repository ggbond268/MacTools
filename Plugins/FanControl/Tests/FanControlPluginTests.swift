import XCTest
import MacToolsPluginKit
@testable import FanControlPlugin

@MainActor
final class FanControlPluginTests: XCTestCase {

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
        XCTAssertNotNil(plugin.rowState.errorMessage)

        plugin.handleAction(.setDisclosureExpanded(false))
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testDeletingActiveCustomPresetResetsToAuto() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)
        let preset = plugin.presetStore.addCustomPreset()!
        plugin.presetStore.setActivePreset(id: preset.id)

        plugin.handleAction(.invokeAction(controlID: "fan-delete-preset"))

        XCTAssertEqual(writer.appliedStrategy, .auto)
    }

    func testDeactivateAfterSuccessfulManualPresetRestoresAuto() {
        let writer = MockSMCWriter()
        let plugin = makePlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
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
        XCTAssertNotNil(plugin.rowState.errorMessage)

        plugin.deactivate(reason: .hostShutdown)
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
