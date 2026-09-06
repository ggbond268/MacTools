import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class CloudPreferencesSyncCoordinatorTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testInitialStateAndConfiguration() {
        let defaults = makeDefaults()
        let coordinator = CloudPreferencesSyncCoordinator(userDefaults: defaults)

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(coordinator.status, .offline(reason: .disabled))
        XCTAssertNil(coordinator.syncDirectoryURL)

        coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.status, .offline(reason: .folderNotConfigured))

        let missingDir = makeTemporaryDirectoryURL().appendingPathComponent("does-not-exist")
        coordinator.setSyncDirectoryURL(missingDir)
        XCTAssertEqual(coordinator.status, .offline(reason: .folderNotFound))

        let validDir = makeTemporaryDirectoryURL()
        coordinator.setSyncDirectoryURL(validDir)
        XCTAssertEqual(coordinator.status, .synced(lastSyncedAt: nil))

        coordinator.setEnabled(false)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(coordinator.status, .offline(reason: .disabled))
    }

    func testExportCreatesVersionedSnapshotAtomically() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = CloudPreferencesSyncCoordinator(
            userDefaults: defaults,
            debounceDelay: .zero
        )
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: "test-plugin-a")
        }

        coordinator.setSyncDirectoryURL(directory)
        coordinator.setEnabled(true)

        try await coordinator.syncNow()

        let syncFile = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncFile.path))

        let data = try Data(contentsOf: syncFile)
        let snapshot = try CloudPreferencesSnapshot.decodeJSON(data)

        XCTAssertEqual(snapshot.version, CloudPreferencesSnapshot.currentVersion)
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(snapshot.deviceID, coordinator.localDeviceID)
        XCTAssertEqual(snapshot.backup.pluginDisplay.orderedPluginIDs, ["test-plugin-a"])
        XCTAssertEqual(coordinator.currentGeneration, 1)
        XCTAssertNotNil(coordinator.lastSyncedAt)
        XCTAssertEqual(coordinator.status, .synced(lastSyncedAt: coordinator.lastSyncedAt))
    }

    func testIncomingExternalSnapshotIsImportedAndAdvancesGeneration() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = CloudPreferencesSyncCoordinator(
            userDefaults: defaults,
            debounceDelay: .zero
        )

        var importedBackup: PreferencesBackup?
        coordinator.importHandler = { backup in
            importedBackup = backup
        }

        coordinator.setSyncDirectoryURL(directory)
        coordinator.setEnabled(true)

        let externalTimestamp = Date(timeIntervalSince1970: floor(Date.now.addingTimeInterval(-10).timeIntervalSince1970))
        let externalSnapshot = CloudPreferencesSnapshot(
            version: 1,
            generation: 15,
            timestamp: externalTimestamp,
            deviceID: "external-mac-device-id",
            deviceName: "MacBook Pro",
            backup: makeBackup(marker: "imported-plugin")
        )
        let syncFile = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try externalSnapshot.encodedJSON().write(to: syncFile, options: .atomic)

        await coordinator.checkForIncomingSnapshots()

        XCTAssertNotNil(importedBackup)
        XCTAssertEqual(importedBackup?.pluginDisplay.orderedPluginIDs, ["imported-plugin"])
        XCTAssertEqual(coordinator.currentGeneration, 15)
        XCTAssertEqual(coordinator.lastSyncedAt?.timeIntervalSince1970 ?? 0, externalTimestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(coordinator.status, .synced(lastSyncedAt: coordinator.lastSyncedAt))
    }

    func testIncomingOlderSnapshotIsRejected() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = CloudPreferencesSyncCoordinator(
            userDefaults: defaults,
            debounceDelay: .zero
        )

        var currentMarker = "newer-local"
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: currentMarker)
        }
        coordinator.setSyncDirectoryURL(directory)
        coordinator.setEnabled(true)

        // Advance to generation 20 locally
        for i in 0..<20 {
            currentMarker = "newer-local-\(i)"
            try await coordinator.syncNow()
        }
        XCTAssertEqual(coordinator.currentGeneration, 20)

        var importedBackup: PreferencesBackup?
        coordinator.importHandler = { backup in
            importedBackup = backup
        }

        // External snapshot has older generation 5
        let externalSnapshot = CloudPreferencesSnapshot(
            version: 1,
            generation: 5,
            timestamp: Date.now.addingTimeInterval(-3600),
            deviceID: "external-device",
            deviceName: "Older Mac",
            backup: makeBackup(marker: "older-external")
        )
        let syncFile = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try externalSnapshot.encodedJSON().write(to: syncFile, options: .atomic)

        await coordinator.checkForIncomingSnapshots()

        XCTAssertNil(importedBackup, "Older external snapshot must not overwrite newer local preferences")
        XCTAssertEqual(coordinator.currentGeneration, 20)
    }

    func testSelfDeviceEchoIsIgnored() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = CloudPreferencesSyncCoordinator(
            userDefaults: defaults,
            debounceDelay: .zero
        )

        var importedBackup: PreferencesBackup?
        coordinator.importHandler = { backup in
            importedBackup = backup
        }

        coordinator.setSyncDirectoryURL(directory)
        coordinator.setEnabled(true)

        // Snapshot written by same deviceID
        let selfSnapshot = CloudPreferencesSnapshot(
            version: 1,
            generation: coordinator.currentGeneration,
            timestamp: Date.now,
            deviceID: coordinator.localDeviceID,
            deviceName: "This Mac",
            backup: makeBackup(marker: "self-echo")
        )
        let syncFile = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try selfSnapshot.encodedJSON().write(to: syncFile, options: .atomic)

        await coordinator.checkForIncomingSnapshots()

        XCTAssertNil(importedBackup, "Echo snapshot from same device must be ignored")
    }

    func testMachineSpecificPreferencesAreFiltered() throws {
        let displayActionRef = ActionReference(
            key: ActionKey(providerID: "display-brightness", actionID: "adjust-display"),
            parameters: try ActionParameterSet([
                "displayID": .integer(12345),
                "delta": .double(0.1)
            ])
        )
        let portableActionRef = ActionReference(
            key: ActionKey(providerID: "test-plugin", actionID: "do-something"),
            parameters: try ActionParameterSet([
                "value": .string("portable-setting")
            ])
        )

        let portableRule = AutomationRule(
            name: "Portable Display Rule",
            workflowID: UUID(),
            trigger: .display(DisplayAutomationTrigger(
                event: .connected,
                displayNameContains: "Studio Display"
            ))
        )
        let localDisplayRule = AutomationRule(
            name: "Local Display Rule",
            workflowID: UUID(),
            trigger: .display(DisplayAutomationTrigger(
                event: .connected,
                displayIdentifier: "987654"
            ))
        )
        let localCalendarRule = AutomationRule(
            name: "Local Calendar Rule",
            workflowID: UUID(),
            trigger: .calendar(CalendarAutomationTrigger(
                phase: .starts,
                calendarIdentifier: "eventkit-uuid-1234"
            ))
        )

        let fanPayload = """
        {
            "version": 1,
            "customPresets": [
                { "id": "custom-quiet", "name": "Quiet Mode", "isBuiltIn": false }
            ],
            "activePresetID": "custom-quiet"
        }
        """

        let pluginJsonPayload = """
        {
            "normalSetting": "active",
            "displayID": "12345",
            "sensorHardwareID": "SMC-01",
            "nested": {
                "safe": true,
                "hardwareID": "HW-99"
            }
        }
        """

        let rawBackup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.dark.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["plugin-1"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [
                "portable.action": .custom(ShortcutBinding(keyCode: 10, modifiers: [.command])),
                "display.12345.brightness": .custom(ShortcutBinding(keyCode: 11, modifiers: [.command]))
            ],
            actionShortcutAssignments: [
                ActionShortcutAssignmentRecord(
                    reference: displayActionRef,
                    binding: ShortcutBinding(keyCode: 20, modifiers: [.command])
                ),
                ActionShortcutAssignmentRecord(
                    reference: portableActionRef,
                    binding: ShortcutBinding(keyCode: 21, modifiers: [.command])
                )
            ],
            pluginPreferences: [
                "fan-control": Data(fanPayload.utf8),
                "generic-plugin": Data(pluginJsonPayload.utf8)
            ],
            automationRules: [portableRule, localDisplayRule, localCalendarRule]
        )

        let sanitized = CloudPreferencesSyncCoordinator.filterMachineSpecificPreferences(rawBackup)

        // 1. Display shortcuts filtered out
        XCTAssertNil(sanitized.shortcutCustomizations["display.12345.brightness"])
        XCTAssertNotNil(sanitized.shortcutCustomizations["portable.action"])

        // 2. Action assignments with displayID parameter removed
        XCTAssertEqual(sanitized.actionShortcutAssignments.count, 1)
        XCTAssertEqual(sanitized.actionShortcutAssignments.first?.reference, portableActionRef)

        // 3. Local-only rules removed
        XCTAssertEqual(sanitized.automationRules?.count, 1)
        XCTAssertEqual(sanitized.automationRules?.first?.name, "Portable Display Rule")

        // 4. Fan control activePresetID reset to builtin-auto
        let sanitizedFanData = try XCTUnwrap(sanitized.pluginPreferences["fan-control"])
        let fanDict = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitizedFanData) as? [String: Any])
        XCTAssertEqual(fanDict["activePresetID"] as? String, "builtin-auto")
        XCTAssertNotNil(fanDict["customPresets"])

        // 5. Generic plugin JSON stripped of displayID and hardware IDs
        let sanitizedGenericData = try XCTUnwrap(sanitized.pluginPreferences["generic-plugin"])
        let genericDict = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitizedGenericData) as? [String: Any])
        XCTAssertEqual(genericDict["normalSetting"] as? String, "active")
        XCTAssertNil(genericDict["displayID"])
        XCTAssertNil(genericDict["sensorHardwareID"])
        let nested = genericDict["nested"] as? [String: Any]
        XCTAssertEqual(nested?["safe"] as? Bool, true)
        XCTAssertNil(nested?["hardwareID"])
    }

    func testTwoCoordinatorsSyncRoundtrip() async throws {
        let directory = makeTemporaryDirectoryURL()

        let defaultsA = makeDefaults()
        let coordinatorA = CloudPreferencesSyncCoordinator(
            userDefaults: defaultsA,
            debounceDelay: .zero
        )
        var backupA = makeBackup(marker: "from-mac-a", appearance: .dark)
        coordinatorA.snapshotProvider = { backupA }
        coordinatorA.setSyncDirectoryURL(directory)
        coordinatorA.setEnabled(true)

        let defaultsB = makeDefaults()
        let coordinatorB = CloudPreferencesSyncCoordinator(
            userDefaults: defaultsB,
            debounceDelay: .zero
        )
        var importedAtB: PreferencesBackup?
        coordinatorB.importHandler = { backup in
            importedAtB = backup
        }
        coordinatorB.setSyncDirectoryURL(directory)
        coordinatorB.setEnabled(true)

        // Device A exports
        try await coordinatorA.syncNow()

        // Device B imports
        await coordinatorB.checkForIncomingSnapshots()
        XCTAssertEqual(importedAtB?.pluginDisplay.orderedPluginIDs, ["from-mac-a"])
        XCTAssertEqual(coordinatorB.currentGeneration, 1)

        // Now Device B modifies preferences and exports
        var backupB = makeBackup(marker: "from-mac-b", appearance: .light)
        coordinatorB.snapshotProvider = { backupB }
        try await coordinatorB.syncNow()
        XCTAssertEqual(coordinatorB.currentGeneration, 2)

        // Device A imports from Device B
        var importedAtA: PreferencesBackup?
        coordinatorA.importHandler = { backup in
            importedAtA = backup
        }
        await coordinatorA.checkForIncomingSnapshots()
        XCTAssertEqual(importedAtA?.pluginDisplay.orderedPluginIDs, ["from-mac-b"])
        XCTAssertEqual(coordinatorA.currentGeneration, 2)
    }

    // MARK: - Helpers

    private func makeBackup(
        marker: String,
        appearance: AppAppearancePreference = .system
    ) -> PreferencesBackup {
        PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: appearance.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [marker],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [:],
            exportedAt: .now
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CloudPreferencesSyncCoordinatorTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudPreferencesSyncCoordinatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
