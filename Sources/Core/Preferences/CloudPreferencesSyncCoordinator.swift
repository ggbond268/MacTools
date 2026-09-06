import Foundation
import MacToolsPluginKit

@MainActor
final class CloudPreferencesSyncCoordinator {
    static let enabledUserDefaultsKey = "preferencesSync.cloud.enabled"
    static let directoryPathUserDefaultsKey = "preferencesSync.cloud.directoryPath"
    static let deviceIDUserDefaultsKey = "preferencesSync.cloud.deviceID"
    static let generationUserDefaultsKey = "preferencesSync.cloud.generation"
    static let lastSyncedAtUserDefaultsKey = "preferencesSync.cloud.lastSyncedAt"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let debounceDelay: Duration
    private let observerQueue = DispatchQueue(
        label: "app.ggbond.MacTools.CloudPreferencesSyncCoordinator.observer",
        qos: .utility
    )

    private(set) var isEnabled: Bool
    private(set) var syncDirectoryURL: URL?
    private(set) var localDeviceID: String
    private(set) var currentGeneration: UInt64
    private(set) var lastSyncedAt: Date?
    private(set) var status: CloudPreferencesSyncStatus = .offline(reason: .disabled)

    var snapshotProvider: (() -> PreferencesBackup?)?
    var importHandler: ((PreferencesBackup) throws -> Void)?
    var statusHandler: ((CloudPreferencesSyncStatus) -> Void)?
    var directoryURLHandler: ((URL?) -> Void)?
    var failureHandler: ((Error) -> Void)?

    private var pendingExportTask: Task<Void, Never>?
    private var pendingCheckTask: Task<Void, Never>?
    private var isApplyingExternalSnapshot = false
    private var lastMeaningfulBackup: PreferencesBackup?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var filePresenter: SyncFolderPresenter?

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        debounceDelay: Duration = .seconds(2)
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.debounceDelay = debounceDelay

        let savedDeviceID = userDefaults.string(forKey: Self.deviceIDUserDefaultsKey)
        if let savedDeviceID, !savedDeviceID.isEmpty {
            self.localDeviceID = savedDeviceID
        } else {
            let newID = UUID().uuidString
            self.localDeviceID = newID
            userDefaults.set(newID, forKey: Self.deviceIDUserDefaultsKey)
        }

        if let generationString = userDefaults.string(forKey: Self.generationUserDefaultsKey),
           let generation = UInt64(generationString) {
            self.currentGeneration = generation
        } else {
            let generation = UInt64(userDefaults.integer(forKey: Self.generationUserDefaultsKey))
            self.currentGeneration = generation
        }

        let lastSyncedTimestamp = userDefaults.double(forKey: Self.lastSyncedAtUserDefaultsKey)
        if lastSyncedTimestamp > 0 {
            self.lastSyncedAt = Date(timeIntervalSince1970: lastSyncedTimestamp)
        } else {
            self.lastSyncedAt = nil
        }

        self.isEnabled = userDefaults.bool(forKey: Self.enabledUserDefaultsKey)

        if let savedPath = userDefaults.string(forKey: Self.directoryPathUserDefaultsKey), !savedPath.isEmpty {
            let expanded = NSString(string: savedPath).expandingTildeInPath
            self.syncDirectoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            self.syncDirectoryURL = nil
        }

        updateStatus()
    }

    isolated deinit {
        stopObservingDirectory()
        pendingExportTask?.cancel()
        pendingCheckTask?.cancel()
    }

    func start() {
        if isEnabled, syncDirectoryURL != nil {
            startObservingDirectory()
            Task { [weak self] in
                await self?.checkForIncomingSnapshots()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledUserDefaultsKey)

        if enabled {
            startObservingDirectory()
            updateStatus()
            committedPreferencesDidChange()
            Task { [weak self] in
                await self?.checkForIncomingSnapshots()
            }
        } else {
            stopObservingDirectory()
            pendingExportTask?.cancel()
            pendingExportTask = nil
            pendingCheckTask?.cancel()
            pendingCheckTask = nil
            updateStatus()
        }
    }

    func setSyncDirectoryURL(_ url: URL?) {
        guard syncDirectoryURL != url else { return }
        stopObservingDirectory()

        syncDirectoryURL = url
        if let url {
            userDefaults.set(url.path, forKey: Self.directoryPathUserDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.directoryPathUserDefaultsKey)
        }
        directoryURLHandler?(url)

        if isEnabled, url != nil {
            startObservingDirectory()
            updateStatus()
            committedPreferencesDidChange()
            Task { [weak self] in
                await self?.checkForIncomingSnapshots()
            }
        } else {
            updateStatus()
        }
    }

    func committedPreferencesDidChange() {
        guard isEnabled, !isApplyingExternalSnapshot, syncDirectoryURL != nil else { return }
        pendingExportTask?.cancel()
        pendingExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.debounceDelay > .zero {
                    try await Task.sleep(for: self.debounceDelay)
                }
                guard !Task.isCancelled else { return }
                try await self.performExport()
            } catch is CancellationError {
                return
            } catch {
                self.handleError(error)
            }
        }
    }

    func syncNow() async throws {
        pendingExportTask?.cancel()
        pendingExportTask = nil
        pendingCheckTask?.cancel()
        pendingCheckTask = nil

        guard isEnabled else {
            updateStatus()
            return
        }
        guard syncDirectoryURL != nil else {
            updateStatus()
            return
        }

        await checkForIncomingSnapshots()
        try await performExport()
    }

    func flushPendingExportBeforeTermination() {
        guard isEnabled, !isApplyingExternalSnapshot, let url = syncDirectoryURL else { return }
        pendingExportTask?.cancel()
        pendingExportTask = nil

        guard let backup = snapshotProvider?() else { return }
        let sanitized = Self.filterMachineSpecificPreferences(backup)
        if let last = lastMeaningfulBackup, last.hasSameMeaningfulContent(as: sanitized) {
            return
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            currentGeneration &+= 1
            userDefaults.set(String(currentGeneration), forKey: Self.generationUserDefaultsKey)

            let now = Date.now
            let snapshot = CloudPreferencesSnapshot(
                version: CloudPreferencesSnapshot.currentVersion,
                generation: currentGeneration,
                timestamp: now,
                deviceID: localDeviceID,
                deviceName: Host.current().localizedName ?? "Mac",
                backup: sanitized
            )
            let data = try snapshot.encodedJSON()
            let destinationURL = url.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
            try data.write(to: destinationURL, options: .atomic)

            lastSyncedAt = now
            userDefaults.set(now.timeIntervalSince1970, forKey: Self.lastSyncedAtUserDefaultsKey)
            lastMeaningfulBackup = sanitized
        } catch {
            handleError(error)
        }
    }

    // MARK: - Export Logic

    private func performExport() async throws {
        guard isEnabled, let url = syncDirectoryURL else {
            updateStatus()
            return
        }

        guard let backup = snapshotProvider?() else {
            throw CocoaError(.fileNoSuchFile)
        }

        let sanitized = Self.filterMachineSpecificPreferences(backup)
        let destinationURL = url.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)

        if let last = lastMeaningfulBackup,
           last.hasSameMeaningfulContent(as: sanitized),
           fileManager.fileExists(atPath: destinationURL.path) {
            updateStatus()
            return
        }

        updateStatus(to: .syncing)

        try await Task.detached(priority: .utility) { [url] in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value

        currentGeneration &+= 1
        userDefaults.set(String(currentGeneration), forKey: Self.generationUserDefaultsKey)

        let now = Date.now
        let snapshot = CloudPreferencesSnapshot(
            version: CloudPreferencesSnapshot.currentVersion,
            generation: currentGeneration,
            timestamp: now,
            deviceID: localDeviceID,
            deviceName: Host.current().localizedName ?? "Mac",
            backup: sanitized
        )
        let data = try snapshot.encodedJSON()

        try await Task.detached(priority: .utility) {
            try data.write(to: destinationURL, options: .atomic)
        }.value

        lastSyncedAt = now
        userDefaults.set(now.timeIntervalSince1970, forKey: Self.lastSyncedAtUserDefaultsKey)
        lastMeaningfulBackup = sanitized

        updateStatus(to: .synced(lastSyncedAt: lastSyncedAt))
    }

    // MARK: - Incoming Snapshot Check

    func checkForIncomingSnapshots() async {
        guard isEnabled, let url = syncDirectoryURL else {
            updateStatus()
            return
        }

        let fileURL = url.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            updateStatus()
            return
        }

        do {
            let data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: fileURL)
            }.value

            let snapshot = try CloudPreferencesSnapshot.decodeJSON(data)

            if snapshot.deviceID == localDeviceID {
                if snapshot.generation > currentGeneration {
                    currentGeneration = snapshot.generation
                    userDefaults.set(String(currentGeneration), forKey: Self.generationUserDefaultsKey)
                }
                updateStatus()
                return
            }

            let isNewer = snapshot.generation > currentGeneration
                || (snapshot.generation == currentGeneration && snapshot.timestamp > (lastSyncedAt ?? .distantPast))

            if isNewer {
                updateStatus(to: .syncing)
                let sanitized = Self.filterMachineSpecificPreferences(snapshot.backup)
                isApplyingExternalSnapshot = true
                defer { isApplyingExternalSnapshot = false }

                try importHandler?(sanitized)

                currentGeneration = max(currentGeneration, snapshot.generation)
                userDefaults.set(String(currentGeneration), forKey: Self.generationUserDefaultsKey)
                lastSyncedAt = snapshot.timestamp
                userDefaults.set(snapshot.timestamp.timeIntervalSince1970, forKey: Self.lastSyncedAtUserDefaultsKey)
                lastMeaningfulBackup = sanitized

                updateStatus(to: .synced(lastSyncedAt: lastSyncedAt))
            } else {
                updateStatus()
            }
        } catch {
            handleError(error)
        }
    }

    private func scheduleIncomingSnapshotCheck() {
        guard isEnabled, syncDirectoryURL != nil else { return }
        pendingCheckTask?.cancel()
        pendingCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await self.checkForIncomingSnapshots()
            } catch {
                return
            }
        }
    }

    // MARK: - Directory Observation

    private func startObservingDirectory() {
        stopObservingDirectory()
        guard let url = syncDirectoryURL else { return }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleIncomingSnapshotCheck()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.directorySource = source

        let presenter = SyncFolderPresenter(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleIncomingSnapshotCheck()
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.filePresenter = presenter
    }

    private func stopObservingDirectory() {
        if let presenter = filePresenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            filePresenter = nil
        }
        if let source = directorySource {
            source.cancel()
            directorySource = nil
            fileDescriptor = -1
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Status Management

    private func updateStatus(to explicitStatus: CloudPreferencesSyncStatus? = nil) {
        if let explicitStatus {
            status = explicitStatus
            statusHandler?(status)
            return
        }

        guard isEnabled else {
            status = .offline(reason: .disabled)
            statusHandler?(status)
            return
        }

        guard let url = syncDirectoryURL else {
            status = .offline(reason: .folderNotConfigured)
            statusHandler?(status)
            return
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            status = .offline(reason: .folderNotFound)
            statusHandler?(status)
            return
        }

        status = .synced(lastSyncedAt: lastSyncedAt)
        statusHandler?(status)
    }

    private func handleError(_ error: Error) {
        status = .error(message: error.localizedDescription)
        statusHandler?(status)
        failureHandler?(error)
    }

    // MARK: - Machine-Specific Filtering

    static func filterMachineSpecificPreferences(_ backup: PreferencesBackup) -> PreferencesBackup {
        let application = backup.application
        let pluginDisplay = backup.pluginDisplay

        let shortcutCustomizations = backup.shortcutCustomizations.filter { key, _ in
            !isMachineSpecificIdentifier(key)
        }

        let actionShortcutAssignments = backup.actionShortcutAssignments.filter { assignment in
            !isMachineSpecificActionReference(assignment.reference)
        }

        let actionInvocationPresets = backup.actionInvocationPresets?.filter { preset in
            !isMachineSpecificActionReference(preset.reference)
        }

        let workflows = backup.workflows?.compactMap { workflow -> WorkflowDefinition? in
            let filteredSteps = workflow.steps.filter { step in
                !isMachineSpecificActionReference(step.reference)
            }
            return WorkflowDefinition(
                id: workflow.id,
                name: workflow.name,
                steps: filteredSteps
            )
        }

        let automationRules = backup.automationRules?.filter { rule in
            AutomationRulePortabilityAnalysis.isPortable(rule)
        }

        var pluginPreferences = backup.pluginPreferences
        for (pluginID, data) in pluginPreferences {
            if let sanitized = sanitizePluginPreferenceData(pluginID: pluginID, data: data) {
                pluginPreferences[pluginID] = sanitized
            } else {
                pluginPreferences.removeValue(forKey: pluginID)
            }
        }

        var pluginPreferenceActionReferences = backup.pluginPreferenceActionReferences
        for (pluginID, references) in pluginPreferenceActionReferences {
            pluginPreferenceActionReferences[pluginID] = references.filter {
                !isMachineSpecificActionReference($0)
            }
        }

        return PreferencesBackup(
            application: application,
            pluginDisplay: pluginDisplay,
            shortcutCustomizations: shortcutCustomizations,
            actionShortcutAssignments: actionShortcutAssignments,
            pluginPreferences: pluginPreferences,
            pluginPreferenceActionReferences: pluginPreferenceActionReferences,
            actionInvocationPresets: actionInvocationPresets,
            workflows: workflows,
            automationRules: automationRules,
            selection: backup.selection,
            exportedAt: backup.exportedAt
        )
    }

    private static func isMachineSpecificIdentifier(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        if lower.contains("display.") || lower.contains("display_") || lower.contains("screen.") {
            let digits = lower.filter { $0.isNumber }
            if digits.count >= 3 { return true }
        }
        if lower.contains("sensor.") || lower.contains("fan-hardware.") {
            return true
        }
        return false
    }

    private static func isMachineSpecificActionReference(_ reference: ActionReference) -> Bool {
        let machineSpecificKeys: Set<String> = [
            "displayID", "displayIdentifier", "display_id", "screenID", "sensorID",
            "sensorHardwareID", "hardwareID", "fanID", "targetDisplayIDs"
        ]

        for entry in reference.parameters.entries {
            if machineSpecificKeys.contains(entry.name) {
                return true
            }
            if case let .string(str) = entry.value, isMachineSpecificIdentifier(str) {
                return true
            }
        }

        let provider = reference.key.providerID.lowercased()
        if provider.contains("display-brightness") || provider.contains("display-resolution") || provider.contains("display-sleep") || provider.contains("display-true-color") {
            let action = reference.key.actionID.lowercased()
            if action.contains("display.") || isMachineSpecificIdentifier(action) {
                return true
            }
        }

        return false
    }

    private static func sanitizePluginPreferenceData(pluginID: String, data: Data) -> Data? {
        guard var jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }

        if pluginID == "fan-control" {
            // Fan hardware differs across machines; reset activePresetID to automatic control
            // while preserving user custom preset definitions.
            jsonObject["activePresetID"] = "builtin-auto"
        }

        let sanitizedObject = sanitizeJSONValue(jsonObject)
        return try? JSONSerialization.data(withJSONObject: sanitizedObject, options: [.sortedKeys])
    }

    private static func sanitizeJSONValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            let machineKeys: Set<String> = [
                "displayID", "displayIdentifier", "screenID", "sensorID",
                "sensorHardwareID", "hardwareID", "hardwareSensors", "hardwareFanSpeeds"
            ]
            var result: [String: Any] = [:]
            for (k, v) in dict where !machineKeys.contains(k) {
                result[k] = sanitizeJSONValue(v)
            }
            return result
        } else if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0) }
        }
        return value
    }
}

private final class SyncFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    let onFolderChanged: @Sendable () -> Void

    init(url: URL, onFolderChanged: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.onFolderChanged = onFolderChanged
    }

    func presentedItemDidChange() {
        onFolderChanged()
    }

    func presentedSubitemDidChange(at url: URL) {
        onFolderChanged()
    }
}
