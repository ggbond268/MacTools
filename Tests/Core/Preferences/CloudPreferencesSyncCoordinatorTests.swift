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

    func testPendingLocalEditWinsOverHigherGenerationSnapshot() async throws {
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
        XCTAssertEqual(coordinator.currentGeneration, 15)
        try await coordinator.syncNow()
        let saved = try readSnapshot(in: directory)
        XCTAssertEqual(saved.generation, 16)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["newer-local"])
    }

    func testLocalEditDuringIncomingReadSurvivesEvenAfterItsExportCompletes() async throws {
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

        let exported = expectation(description: "Local edit exported while remote read is suspended")
        coordinator.statusHandler = { status in
            if case .synced = status, coordinator.currentGeneration == 2 {
                exported.fulfill()
            }
        }
        localBackup = makeBackup(marker: "local-edit-during-read")
        coordinator.committedPreferencesDidChange()
        await fulfillment(of: [exported], timeout: 5)
        coordinator.statusHandler = nil
        await gate.resume()
        await check.value

        XCTAssertEqual(importCount, 0)
        XCTAssertEqual(localBackup.pluginDisplay.orderedPluginIDs, ["local-edit-during-read"])
        try await coordinator.syncNow()
        let saved = try readSnapshot(in: directory)
        XCTAssertGreaterThan(saved.generation, 100)
        XCTAssertEqual(saved.backup.pluginDisplay.orderedPluginIDs, ["local-edit-during-read"])
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
        var reads = 0
        coordinator.snapshotProvider = {
            reads += 1
            // performExport checks availability, then exportSnapshot captures the value.
            if reads == 2 { captured.fulfill() }
            return localBackup
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

    // MARK: - Helpers

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
