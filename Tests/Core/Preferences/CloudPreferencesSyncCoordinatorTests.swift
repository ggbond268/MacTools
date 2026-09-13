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

    func testManualAndCloudArchivesUseOneInterchangeableEnvelope() throws {
        let backup = makeBackup(marker: "shared-archive")
        let manual = PreferencesArchiveDocument(
            scope: .full,
            documentID: "manual-document",
            timestamp: Date(timeIntervalSince1970: 100),
            backup: backup
        )
        let cloud = CloudPreferencesSnapshot(
            generation: 7,
            timestamp: Date(timeIntervalSince1970: 200),
            deviceID: "remote-device",
            deviceName: "Remote Mac",
            backup: backup
        )

        let decodedManual = try PreferencesArchiveDocument.decodeJSON(manual.encodedJSON())
        let decodedCloud = try PreferencesArchiveDocument.decodeJSON(cloud.encodedJSON())

        XCTAssertEqual(decodedManual.scope, .full)
        XCTAssertFalse(decodedManual.isCloudSnapshot)
        XCTAssertEqual(decodedCloud.scope, .portable)
        XCTAssertTrue(decodedCloud.isCloudSnapshot)
        XCTAssertTrue(
            try PreferencesBackup.decodeJSON(manual.encodedJSON()).hasSameMeaningfulContent(as: backup)
        )
        XCTAssertTrue(
            try PreferencesBackup.decodeJSON(cloud.encodedJSON()).hasSameMeaningfulContent(as: backup)
        )
    }

    func testManualArchiveSeedsSyncFolderAndBecomesCanonicalCloudDocument() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = CloudPreferencesSyncCoordinator(
            userDefaults: defaults,
            debounceDelay: .zero
        )
        var currentBackup = makeBackup(marker: "local-before-seed")
        coordinator.snapshotProvider = { currentBackup }
        coordinator.importHandler = { currentBackup = $0 }

        let manualBackup = makeBackup(marker: "manual-seed")
        let manualDocument = PreferencesArchiveDocument(
            scope: .full,
            documentID: "manual-sync-seed",
            backup: manualBackup
        )
        let manualURL = directory.appendingPathComponent("MacTools Preferences 2026-09-08_19-00-00.json")
        try manualDocument.encodedJSON().write(to: manualURL, options: .atomic)

        coordinator.setSyncDirectoryURL(directory)
        coordinator.setEnabled(true)
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()

        XCTAssertEqual(currentBackup.pluginDisplay.orderedPluginIDs, ["manual-seed"])
        let canonicalURL = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        let canonical = try CloudPreferencesSnapshot.decodeJSON(Data(contentsOf: canonicalURL))
        XCTAssertTrue(canonical.isCloudSnapshot)
        XCTAssertEqual(canonical.scope, .portable)
        XCTAssertEqual(canonical.backup.pluginDisplay.orderedPluginIDs, ["manual-seed"])

        coordinator.setEnabled(false)
        var reopenedImportCount = 0
        let reopened = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .zero)
        reopened.snapshotProvider = { currentBackup }
        reopened.importHandler = { _ in reopenedImportCount += 1 }
        reopened.setSyncDirectoryURL(directory)
        reopened.setEnabled(true)
        defer { reopened.setEnabled(false) }
        await reopened.checkForIncomingSnapshots()
        XCTAssertEqual(reopenedImportCount, 0, "A consumed manual seed must not be applied again after relaunch")
    }

    func testLegacyBareManualBackupRemainsImportable() throws {
        let backup = makeBackup(marker: "legacy-manual")
        let decoded = try PreferencesBackup.decodeJSON(backup.encodedJSON())
        XCTAssertTrue(decoded.hasSameMeaningfulContent(as: backup))
    }

    func testLegacyCloudSnapshotWithRootMetadataRemainsImportable() throws {
        let backup = makeBackup(marker: "legacy-cloud")
        let backupObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        let legacyObject: [String: Any] = [
            "version": 1,
            "generation": 12,
            "timestamp": "2026-09-08T19:00:00Z",
            "deviceID": "legacy-device",
            "deviceName": "Legacy Mac",
            "backup": backupObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try CloudPreferencesSnapshot.decodeJSON(data)

        XCTAssertEqual(decoded.scope, .portable)
        XCTAssertEqual(decoded.generation, 12)
        XCTAssertEqual(decoded.deviceID, "legacy-device")
        XCTAssertEqual(decoded.deviceName, "Legacy Mac")
        XCTAssertTrue(decoded.backup.hasSameMeaningfulContent(as: backup))
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

    func testEnablingSyncReadsExistingRemoteSnapshotBeforeFirstExport() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let gate = CloudSnapshotReadGate()
        let remoteSnapshot = CloudPreferencesSnapshot(
            generation: 9,
            deviceID: "remote-device",
            deviceName: "Other Mac",
            backup: makeBackup(marker: "remote-preferences")
        )
        let syncFile = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try remoteSnapshot.encodedJSON().write(to: syncFile, options: .atomic)

        let coordinator = CloudPreferencesSyncCoordinator(
            userDefaults: defaults,
            debounceDelay: .zero,
            readSnapshot: { url in
                let data = try Data(contentsOf: url)
                await gate.suspendIfArmed()
                return data
            }
        )
        var currentBackup = makeBackup(marker: "new-local-install")
        let imported = expectation(description: "Existing remote preferences imported")
        coordinator.snapshotProvider = { currentBackup }
        coordinator.importHandler = {
            currentBackup = $0
            imported.fulfill()
        }
        coordinator.setSyncDirectoryURL(directory)
        await gate.arm()
        coordinator.setEnabled(true)
        defer { coordinator.setEnabled(false) }
        await gate.waitUntilSuspended()

        let snapshotWhileReading = try readSnapshot(in: directory)
        XCTAssertEqual(
            snapshotWhileReading.backup.pluginDisplay.orderedPluginIDs,
            ["remote-preferences"],
            "The first local export must not overwrite the remote snapshot while it is being read"
        )

        await gate.resume()
        await fulfillment(of: [imported], timeout: 5)
        XCTAssertEqual(currentBackup.pluginDisplay.orderedPluginIDs, ["remote-preferences"])
        XCTAssertEqual(coordinator.currentGeneration, 9)
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

    func testWorkflowFilteringPreservesDisabledStateAndAllMetadata() throws {
        let portableStep = WorkflowStep(
            reference: ActionReference(key: ActionKey(providerID: "portable", actionID: "run")),
            label: "Portable step",
            delaySeconds: 2,
            errorPolicy: .continueRunning
        )
        let localStep = WorkflowStep(reference: ActionReference(
            key: ActionKey(providerID: "display-brightness", actionID: "adjust"),
            parameters: try ActionParameterSet(["displayID": .integer(12345)])
        ))
        let workflow = WorkflowDefinition(
            name: "Disabled workflow",
            systemImage: "star.fill",
            isEnabled: false,
            steps: [localStep, portableStep],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let backup = makeBackup(marker: "workflow", workflows: [workflow])
        let sanitized = CloudPreferencesSyncCoordinator.filterMachineSpecificPreferences(backup)
        var expected = workflow
        expected.steps = [portableStep]

        XCTAssertEqual(sanitized.workflows, [expected])
        let repeated = CloudPreferencesSyncCoordinator.filterMachineSpecificPreferences(backup)
        XCTAssertTrue(sanitized.hasSameMeaningfulContent(as: repeated))
        XCTAssertTrue(sanitized.hasSameMeaningfulContent(
            as: CloudPreferencesSyncCoordinator.filterMachineSpecificPreferences(sanitized)
        ))
    }

    func testUnchangedWorkflowDoesNotAdvanceExportGeneration() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        let workflow = WorkflowDefinition(name: "Disabled", systemImage: "star", isEnabled: false)
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: "same", workflows: [workflow])
        }
        defer { coordinator.setEnabled(false) }

        try await coordinator.syncNow()
        let firstGeneration = coordinator.currentGeneration
        coordinator.committedPreferencesDidChange()
        try await coordinator.syncNow()

        XCTAssertEqual(coordinator.currentGeneration, firstGeneration)
        let saved = try readSnapshot(in: directory)
        XCTAssertFalse(try XCTUnwrap(saved.backup.workflows?.first).isEnabled)
    }

    func testPendingLocalEditRequiresChoiceBeforeReplacingHigherGenerationSnapshot() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        var localBackup = makeBackup(marker: "initial")
        var importCount = 0
        coordinator.snapshotProvider = { localBackup }
        coordinator.importHandler = { localBackup = $0; importCount += 1 }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()

        localBackup = makeBackup(marker: "newer-local")
        coordinator.committedPreferencesDidChange()
        let remote = CloudPreferencesSnapshot(
            generation: 15,
            timestamp: Date.now.addingTimeInterval(-10),
            deviceID: "remote",
            deviceName: "Remote Mac",
            backup: makeBackup(marker: "older-remote")
        )
        try remote.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        await coordinator.checkForIncomingSnapshots()

        XCTAssertEqual(importCount, 0)
        XCTAssertEqual(localBackup.pluginDisplay.orderedPluginIDs, ["newer-local"])
        XCTAssertEqual(coordinator.status, .conflict(deviceName: "Remote Mac"))
        try await coordinator.syncNow()
        XCTAssertEqual(try readSnapshot(in: directory).documentID, remote.documentID)
        try await coordinator.resolveConflict(.local)
        let saved = try readSnapshot(in: directory)
        XCTAssertEqual(saved.generation, 16)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["newer-local"])
    }

    func testLocalEditDuringIncomingReadPreservesBothVersionsUntilChoice() async throws {
        let directory = makeTemporaryDirectoryURL()
        let gate = CloudSnapshotReadGate()
        let coordinator = makeConfiguredCoordinator(directory: directory, debounceDelay: .zero) { url in
            let data = try Data(contentsOf: url)
            await gate.suspendIfArmed()
            return data
        }
        var localBackup = makeBackup(marker: "initial")
        var importCount = 0
        coordinator.snapshotProvider = { localBackup }
        coordinator.importHandler = { localBackup = $0; importCount += 1 }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        let remote = CloudPreferencesSnapshot(
            generation: 100,
            deviceID: "remote",
            deviceName: "Remote Mac",
            backup: makeBackup(marker: "remote-before-local-edit")
        )
        try remote.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        await gate.arm()
        let check = Task { await coordinator.checkForIncomingSnapshots() }
        await gate.waitUntilSuspended()

        localBackup = makeBackup(marker: "local-edit-during-read")
        coordinator.committedPreferencesDidChange()
        await gate.resume()
        await check.value

        XCTAssertEqual(importCount, 0)
        XCTAssertEqual(localBackup.pluginDisplay.orderedPluginIDs, ["local-edit-during-read"])
        try await coordinator.syncNow()
        let saved = try readSnapshot(in: directory)
        XCTAssertEqual(coordinator.status, .conflict(deviceName: "Remote Mac"))
        XCTAssertEqual(saved.documentID, remote.documentID)
        try await coordinator.resolveConflict(.local)
        XCTAssertEqual(try readSnapshot(in: directory).backup.pluginDisplay.orderedPluginIDs, ["local-edit-during-read"])
    }

    func testDisablingSyncDuringIncomingReadPreventsImport() async throws {
        let directory = makeTemporaryDirectoryURL()
        let gate = CloudSnapshotReadGate()
        let coordinator = makeConfiguredCoordinator(directory: directory) { url in
            let data = try Data(contentsOf: url)
            await gate.suspendIfArmed()
            return data
        }
        var imported = false
        coordinator.importHandler = { _ in imported = true }
        let remote = CloudPreferencesSnapshot(
            generation: 15, deviceID: "remote", deviceName: "Remote Mac",
            backup: makeBackup(marker: "remote")
        )
        try remote.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        await gate.arm()
        let check = Task { await coordinator.checkForIncomingSnapshots() }
        await gate.waitUntilSuspended()
        coordinator.setEnabled(false)
        await gate.resume()
        await check.value

        XCTAssertFalse(imported)
        XCTAssertEqual(coordinator.currentGeneration, 0)
        XCTAssertEqual(coordinator.status, .offline(reason: .disabled))
    }

    func testLocalEditDuringExportPreparationIsIncluded() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        var localBackup = makeBackup(marker: "before-export")
        coordinator.snapshotProvider = { localBackup }
        coordinator.statusHandler = { [unowned self] status in
            guard case .syncing = status else { return }
            coordinator.statusHandler = nil
            localBackup = self.makeBackup(marker: "during-export")
            coordinator.committedPreferencesDidChange()
        }
        defer { coordinator.setEnabled(false) }

        try await coordinator.syncNow()

        let saved = try readSnapshot(in: directory)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["during-export"])
        XCTAssertEqual(saved.generation, 1)
    }

    func testChangingFolderDuringExportWritesTheNewFolder() async throws {
        let oldDirectory = makeTemporaryDirectoryURL()
        let newDirectory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: oldDirectory)
        coordinator.snapshotProvider = { [unowned self] in self.makeBackup(marker: "local") }
        coordinator.statusHandler = { status in
            guard case .syncing = status else { return }
            coordinator.statusHandler = nil
            coordinator.setSyncDirectoryURL(newDirectory)
        }
        defer { coordinator.setEnabled(false) }

        try await coordinator.syncNow()

        let saved = try readSnapshot(in: newDirectory)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["local"])
        XCTAssertEqual(coordinator.syncDirectoryURL, newDirectory)
    }

    func testEditDuringSuspendedWriteIsExportedAfterTheOlderWrite() async throws {
        let directory = makeTemporaryDirectoryURL()
        let writer = DispatchQueue(label: "CloudPreferencesSyncCoordinatorTests.writer")
        let coordinator = makeConfiguredCoordinator(directory: directory, writeQueue: writer)
        var localBackup = makeBackup(marker: "initial")
        coordinator.snapshotProvider = { localBackup }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()

        writer.suspend()
        let captured = expectation(description: "First edit captured for the suspended writer")
        coordinator.statusHandler = { status in
            if status.isSyncing {
                coordinator.statusHandler = nil
                captured.fulfill()
            }
        }
        localBackup = makeBackup(marker: "first-edit")
        coordinator.committedPreferencesDidChange()
        let firstSync = Task { try await coordinator.syncNow() }
        await fulfillment(of: [captured], timeout: 5)

        localBackup = makeBackup(marker: "second-edit")
        coordinator.committedPreferencesDidChange()
        let secondSync = Task { try await coordinator.syncNow() }
        writer.resume()
        try await firstSync.value
        try await secondSync.value

        let saved = try readSnapshot(in: directory)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["second-edit"])
        XCTAssertEqual(saved.generation, 3)
        XCTAssertEqual(coordinator.currentGeneration, saved.generation)
    }

    func testTimestampRoundtripPreservesFractionalSecondsAndParentVersion() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.875432)
        let snapshot = CloudPreferencesSnapshot(
            generation: 3, timestamp: timestamp, deviceID: "remote", deviceName: "Remote",
            parentDocumentID: "base-version", backup: makeBackup(marker: "remote")
        )
        let decoded = try CloudPreferencesSnapshot.decodeJSON(snapshot.encodedJSON())
        XCTAssertEqual(decoded.timestamp, timestamp)
        XCTAssertEqual(decoded.syncMetadata?.parentDocumentID, "base-version")
    }

    func testSameGenerationDifferentContentIsPreservedAsConflict() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        var local = makeBackup(marker: "local")
        coordinator.snapshotProvider = { local }
        coordinator.importHandler = { local = $0 }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        let base = try readSnapshot(in: directory)
        let remote = CloudPreferencesSnapshot(
            generation: base.generation, timestamp: base.timestamp.addingTimeInterval(0.1),
            deviceID: "remote", deviceName: "Remote", backup: makeBackup(marker: "remote")
        )
        try remote.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        try await coordinator.syncNow()
        XCTAssertEqual(coordinator.status, .conflict(deviceName: "Remote"))
        XCTAssertEqual(local.pluginDisplay.orderedPluginIDs, ["local"])
        XCTAssertEqual(try readSnapshot(in: directory).documentID, remote.documentID)
    }

    func testRelaunchAndQuitWithoutEditsNeverOverwriteNewerSharedFile() async throws {
        let directory = makeTemporaryDirectoryURL()
        let defaults = configuredDefaults(directory: directory)
        let local = makeBackup(marker: "old-local")
        let first = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        first.snapshotProvider = { local }
        try await first.syncNow()
        first.flushPendingExportBeforeTermination()
        let remote = CloudPreferencesSnapshot(generation: 2, deviceID: "remote", deviceName: "Remote", backup: makeBackup(marker: "new-remote"))
        let url = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        let bytes = try remote.encodedJSON()
        try bytes.write(to: url)
        let reopened = CloudPreferencesSyncCoordinator(userDefaults: defaults)
        reopened.snapshotProvider = { local }
        reopened.flushPendingExportBeforeTermination()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(reopened.currentGeneration, 1)
    }

    func testPendingEditAndConflictSurviveRelaunchAndSharedChoice() async throws {
        let directory = makeTemporaryDirectoryURL()
        let defaults = configuredDefaults(directory: directory)
        var local = makeBackup(marker: "base")
        let first = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        first.snapshotProvider = { local }
        try await first.syncNow()
        local = makeBackup(marker: "pending-local")
        first.committedPreferencesDidChange()
        first.flushPendingExportBeforeTermination()
        XCTAssertEqual(try readSnapshot(in: directory).backup.pluginDisplay.orderedPluginIDs, ["base"])
        let remote = CloudPreferencesSnapshot(generation: 2, deviceID: "remote", deviceName: "Remote", backup: makeBackup(marker: "remote-change"))
        try remote.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        let reopened = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        reopened.snapshotProvider = { local }
        reopened.importHandler = { local = $0 }
        try await reopened.syncNow()
        XCTAssertEqual(reopened.status, .conflict(deviceName: "Remote"))
        reopened.flushPendingExportBeforeTermination()
        let third = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        third.snapshotProvider = { local }
        third.importHandler = { local = $0 }
        defer { third.setEnabled(false) }
        XCTAssertEqual(third.status, .conflict(deviceName: "Remote"))
        try await third.resolveConflict(.shared)
        XCTAssertEqual(local.pluginDisplay.orderedPluginIDs, ["remote-change"])
        XCTAssertEqual(try readSnapshot(in: directory).documentID, remote.documentID)
        let saved = try savedState(defaults, directory: directory)
        XCTAssertEqual(saved.lastResolvedConflict?.local.pluginDisplay.orderedPluginIDs, ["pending-local"])
        XCTAssertEqual(saved.lastResolvedConflict?.shared.documentID, remote.documentID)
        XCTAssertNil(saved.conflict)
    }

    func testPendingEditPublishesAfterRelaunchWhenSharedBaseIsUnchanged() async throws {
        let directory = makeTemporaryDirectoryURL()
        let defaults = configuredDefaults(directory: directory)
        var local = makeBackup(marker: "base")
        let first = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        first.snapshotProvider = { local }
        try await first.syncNow()
        let base = try readSnapshot(in: directory)
        local = makeBackup(marker: "pending")
        first.committedPreferencesDidChange()
        first.flushPendingExportBeforeTermination()
        let reopened = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        reopened.snapshotProvider = { local }
        defer { reopened.setEnabled(false) }
        try await reopened.syncNow()
        let saved = try readSnapshot(in: directory)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["pending"])
        XCTAssertEqual(saved.syncMetadata?.parentDocumentID, base.documentID)
        XCTAssertEqual(saved.generation, 2)
    }

    func testMalformedFileRemovalCanInitializeAccessibleEmptyFolder() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        coordinator.snapshotProvider = { self.makeBackup(marker: "local") }
        defer { coordinator.setEnabled(false) }
        let url = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try Data("{malformed".utf8).write(to: url)
        do { try await coordinator.syncNow(); XCTFail("Malformed input must fail") } catch {}
        XCTAssertNotNil(coordinator.status.errorMessage)
        try FileManager.default.removeItem(at: url)
        try await coordinator.syncNow()
        XCTAssertTrue(coordinator.status.isSynced)
        XCTAssertEqual(try readSnapshot(in: directory).backup.pluginDisplay.orderedPluginIDs, ["local"])
    }

    func testMissingEstablishedFileWaitsAndRecoversWithoutPublishing() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        coordinator.snapshotProvider = { self.makeBackup(marker: "local") }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        let url = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        do { try await coordinator.syncNow(); XCTFail("Missing established file must wait") }
        catch { XCTAssertEqual(error as? CloudPreferencesSyncError, .snapshotMissing) }
        XCTAssertEqual(coordinator.status, .offline(reason: .snapshotMissing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try bytes.write(to: url)
        try await coordinator.syncNow()
        XCTAssertTrue(coordinator.status.isSynced)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUnavailableFolderIsNotRecreatedByRetryOrQuit() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        coordinator.snapshotProvider = { self.makeBackup(marker: "local") }
        try FileManager.default.removeItem(at: directory)
        do { try await coordinator.syncNow(); XCTFail("Unavailable folder must fail") } catch {}
        coordinator.flushPendingExportBeforeTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(coordinator.status, .offline(reason: .folderNotFound))
    }

    func testDefaultCloudReaderRejectsOversizedSparseFileAndCanRetry() async throws {
        let directory = makeTemporaryDirectoryURL()
        let defaults = configuredDefaults(directory: directory)
        let coordinator = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        coordinator.snapshotProvider = { self.makeBackup(marker: "local") }
        defer { coordinator.setEnabled(false) }
        let url = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(PreferencesBackup.maximumFileSize + 1))
        try file.close()
        do { try await coordinator.syncNow(); XCTFail("Oversized input must fail") }
        catch { XCTAssertEqual(error as? PreferencesBackupError, .fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)) }
        try FileManager.default.removeItem(at: url)
        try await coordinator.syncNow()
        XCTAssertTrue(coordinator.status.isSynced)
    }

    func testCloudImportMergesLocalHardwareFieldsWithoutResettingPortableSettings() throws {
        let local = Data(#"{"normalSetting":"old","displayID":"local-display","nested":{"safe":false,"hardwareID":"local-hardware"}}"#.utf8)
        let incoming = Data(#"{"normalSetting":"new","nested":{"safe":true}}"#.utf8)
        let merged = CloudPreferencesSyncCoordinator.preservingMachineSpecificPluginPreferences(incoming: incoming, local: local, pluginID: "generic")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(values["normalSetting"] as? String, "new")
        XCTAssertEqual(values["displayID"] as? String, "local-display")
        let nested = try XCTUnwrap(values["nested"] as? [String: Any])
        XCTAssertEqual(nested["safe"] as? Bool, true)
        XCTAssertEqual(nested["hardwareID"] as? String, "local-hardware")
    }

    private func configuredDefaults(directory: URL) -> UserDefaults {
        let defaults = makeDefaults()
        defaults.set(true, forKey: CloudPreferencesSyncCoordinator.enabledUserDefaultsKey)
        defaults.set(directory.path, forKey: CloudPreferencesSyncCoordinator.directoryPathUserDefaultsKey)
        return defaults
    }

    private func savedState(_ defaults: UserDefaults, directory: URL) throws -> CloudPreferencesSyncState {
        let dictionary = try XCTUnwrap(defaults.dictionary(forKey: CloudPreferencesSyncCoordinator.stateUserDefaultsKey))
        let data = try XCTUnwrap(dictionary[directory.path] as? Data)
        return try JSONDecoder().decode(CloudPreferencesSyncState.self, from: data)
    }

    func testSharedChangeDuringQueuedWritePreservesBothVersions() async throws {
        let directory = makeTemporaryDirectoryURL()
        let writer = DispatchQueue(label: "CloudSyncTests.racingWriter")
        let coordinator = makeConfiguredCoordinator(directory: directory, writeQueue: writer)
        var local = makeBackup(marker: "base")
        coordinator.snapshotProvider = { local }
        coordinator.importHandler = { local = $0 }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        writer.suspend()
        let queued = expectation(description: "Local write prepared")
        coordinator.statusHandler = { status in
            if status.isSyncing { coordinator.statusHandler = nil; queued.fulfill() }
        }
        local = makeBackup(marker: "local-change")
        coordinator.committedPreferencesDidChange()
        let sync = Task { try await coordinator.syncNow() }
        await fulfillment(of: [queued], timeout: 5)
        let remote = CloudPreferencesSnapshot(generation: 2, deviceID: "remote", deviceName: "Remote", backup: makeBackup(marker: "remote-change"))
        try remote.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        writer.resume()
        try await sync.value
        XCTAssertEqual(coordinator.status, .conflict(deviceName: "Remote"))
        XCTAssertEqual(local.pluginDisplay.orderedPluginIDs, ["local-change"])
        XCTAssertEqual(try readSnapshot(in: directory).documentID, remote.documentID)
    }

    func testQuitCancelsQueuedWriteAndKeepsPendingEditForNextLaunch() async throws {
        let directory = makeTemporaryDirectoryURL()
        let defaults = configuredDefaults(directory: directory)
        let writer = DispatchQueue(label: "CloudSyncTests.terminationWriter")
        let coordinator = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60), writeQueue: writer)
        var local = makeBackup(marker: "base")
        coordinator.snapshotProvider = { local }
        try await coordinator.syncNow()
        let base = try readSnapshot(in: directory)
        writer.suspend()
        let queued = expectation(description: "Write queued before quit")
        coordinator.statusHandler = { status in
            if status.isSyncing { coordinator.statusHandler = nil; queued.fulfill() }
        }
        local = makeBackup(marker: "pending")
        coordinator.committedPreferencesDidChange()
        let sync = Task { try await coordinator.syncNow() }
        await fulfillment(of: [queued], timeout: 5)
        coordinator.flushPendingExportBeforeTermination()
        writer.resume()
        try await sync.value
        XCTAssertEqual(try readSnapshot(in: directory).documentID, base.documentID)
        let reopened = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
        reopened.snapshotProvider = { local }
        defer { reopened.setEnabled(false) }
        try await reopened.syncNow()
        XCTAssertEqual(try readSnapshot(in: directory).backup.pluginDisplay.orderedPluginIDs, ["pending"])
    }

    func testConflictChoiceRechecksSharedVersionBeforeApplying() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        var local = makeBackup(marker: "base")
        coordinator.snapshotProvider = { local }
        coordinator.importHandler = { local = $0 }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        local = makeBackup(marker: "local")
        coordinator.committedPreferencesDidChange()
        let first = CloudPreferencesSnapshot(generation: 2, deviceID: "remote", deviceName: "First Mac", backup: makeBackup(marker: "first-remote"))
        let url = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try first.encodedJSON().write(to: url)
        try await coordinator.syncNow()
        let second = CloudPreferencesSnapshot(generation: 3, deviceID: "remote", deviceName: "Second Mac", backup: makeBackup(marker: "second-remote"))
        try second.encodedJSON().write(to: url)
        try await coordinator.resolveConflict(.shared)
        XCTAssertEqual(coordinator.status, .conflict(deviceName: "Second Mac"))
        XCTAssertEqual(local.pluginDisplay.orderedPluginIDs, ["local"])
        try await coordinator.resolveConflict(.shared)
        XCTAssertEqual(local.pluginDisplay.orderedPluginIDs, ["second-remote"])
    }

    func testUnchangedWorkflowEchoDoesNotImportOrConflictAfterLocalEdit() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        let workflow = WorkflowDefinition(name: "Fractional dates")
        var local = makeBackup(marker: "base", workflows: [workflow])
        var imports = 0
        coordinator.snapshotProvider = { local }
        coordinator.importHandler = { local = $0; imports += 1 }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        await coordinator.checkForIncomingSnapshots()
        XCTAssertEqual(imports, 0)
        local = makeBackup(marker: "edit", workflows: [workflow])
        coordinator.committedPreferencesDidChange()
        try await coordinator.syncNow()
        XCTAssertTrue(coordinator.status.isSynced)
        XCTAssertEqual(imports, 0)
        XCTAssertEqual(try readSnapshot(in: directory).backup.pluginDisplay.orderedPluginIDs, ["edit"])
    }

    func testLowerGenerationOfflineEditIsNotSilentlyDiscarded() async throws {
        let directory = makeTemporaryDirectoryURL()
        let coordinator = makeConfiguredCoordinator(directory: directory)
        var local = makeBackup(marker: "base")
        coordinator.snapshotProvider = { local }
        defer { coordinator.setEnabled(false) }
        try await coordinator.syncNow()
        local = makeBackup(marker: "new-local")
        coordinator.committedPreferencesDidChange()
        try await coordinator.syncNow()
        let offline = CloudPreferencesSnapshot(generation: 1, deviceID: "offline", deviceName: "Offline Mac", backup: makeBackup(marker: "offline-edit"))
        try offline.encodedJSON().write(to: directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName))
        try await coordinator.syncNow()
        XCTAssertEqual(coordinator.status, .conflict(deviceName: "Offline Mac"))
        XCTAssertEqual(try readSnapshot(in: directory).documentID, offline.documentID)
    }

    func testFanControlImportPreservesActiveLocalPresetDependency() throws {
        let local = Data(#"{"version":1,"activePresetID":"local-quiet","customPresets":[{"id":"local-quiet","name":"Local Quiet"}]}"#.utf8)
        let incoming = Data(#"{"version":1,"activePresetID":"builtin-auto","customPresets":[{"id":"remote","name":"Remote"}]}"#.utf8)
        let merged = CloudPreferencesSyncCoordinator.preservingMachineSpecificPluginPreferences(incoming: incoming, local: local, pluginID: "fan-control")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(values["activePresetID"] as? String, "local-quiet")
        let presets = try XCTUnwrap(values["customPresets"] as? [[String: Any]])
        XCTAssertEqual(Set(presets.compactMap { $0["id"] as? String }), ["local-quiet", "remote"])
    }

    // MARK: - Helpers

    func testFailedImportDoesNotOverwriteOrConsumeSnapshotAndCanRetry() async throws {
        for isManual in [false, true] {
            let directory = makeTemporaryDirectoryURL()
            let backup = makeBackup(marker: "remote")
            let snapshot = isManual
                ? PreferencesArchiveDocument(scope: .full, backup: backup)
                : CloudPreferencesSnapshot(
                    generation: 15, deviceID: "remote", deviceName: "Remote Mac", backup: backup
                )
            let snapshotURL = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
            let originalData = try snapshot.encodedJSON()
            try originalData.write(to: snapshotURL)
            let defaults = makeDefaults()
            defaults.set(true, forKey: CloudPreferencesSyncCoordinator.enabledUserDefaultsKey)
            defaults.set(directory.path, forKey: CloudPreferencesSyncCoordinator.directoryPathUserDefaultsKey)
            let coordinator = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
            defer { coordinator.setEnabled(false) }
            coordinator.snapshotProvider = { self.makeBackup(marker: "local") }
            coordinator.importHandler = { _ in throw CocoaError(.fileWriteUnknown) }

            do {
                try await coordinator.syncNow()
                XCTFail("An unsuccessful import must fail synchronization.")
            } catch {}
            XCTAssertNotNil(coordinator.status.errorMessage)
            XCTAssertEqual(coordinator.currentGeneration, 0)
            XCTAssertEqual(try Data(contentsOf: snapshotURL), originalData)
            coordinator.flushPendingExportBeforeTermination()
            XCTAssertEqual(try Data(contentsOf: snapshotURL), originalData)

            let retry = CloudPreferencesSyncCoordinator(userDefaults: defaults, debounceDelay: .seconds(60))
            defer { retry.setEnabled(false) }
            var imported: PreferencesBackup?
            retry.snapshotProvider = { self.makeBackup(marker: "local") }
            retry.importHandler = { imported = $0 }
            await retry.checkForIncomingSnapshots()
            XCTAssertEqual(imported?.pluginDisplay.orderedPluginIDs, ["remote"])
        }
    }

    private func makeConfiguredCoordinator(
        directory: URL,
        debounceDelay: Duration = .seconds(60),
        writeQueue: DispatchQueue = DispatchQueue(label: "CloudPreferencesSyncCoordinatorTests.writer"),
        readSnapshot: @escaping @Sendable (URL) async throws -> Data = { url in
            try Data(contentsOf: url)
        }
    ) -> CloudPreferencesSyncCoordinator {
        let defaults = makeDefaults()
        defaults.set(true, forKey: CloudPreferencesSyncCoordinator.enabledUserDefaultsKey)
        defaults.set(directory.path, forKey: CloudPreferencesSyncCoordinator.directoryPathUserDefaultsKey)
        return CloudPreferencesSyncCoordinator(
            userDefaults: defaults, debounceDelay: debounceDelay,
            writeQueue: writeQueue, readSnapshot: readSnapshot
        )
    }

    private func readSnapshot(in directory: URL) throws -> CloudPreferencesSnapshot {
        try CloudPreferencesSnapshot.decodeJSON(Data(contentsOf:
            directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        ))
    }


    private func makeBackup(
        marker: String,
        appearance: AppAppearancePreference = .system,
        workflows: [WorkflowDefinition] = []
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
            workflows: workflows,
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

private actor CloudSnapshotReadGate {
    private var isArmed = false
    private var suspendedRead: CheckedContinuation<Void, Never>?
    private var suspensionObserver: CheckedContinuation<Void, Never>?

    func arm() { isArmed = true }

    func suspendIfArmed() async {
        guard isArmed else { return }
        isArmed = false
        await withCheckedContinuation { continuation in
            suspendedRead = continuation
            suspensionObserver?.resume()
            suspensionObserver = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspendedRead == nil else { return }
        await withCheckedContinuation { suspensionObserver = $0 }
    }

    func resume() {
        suspendedRead?.resume()
        suspendedRead = nil
    }
}
