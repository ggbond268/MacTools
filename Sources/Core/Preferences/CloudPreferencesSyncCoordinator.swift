import Foundation
import MacToolsPluginKit

@MainActor
final class CloudPreferencesSyncCoordinator {
    static let enabledUserDefaultsKey = "preferencesSync.cloud.enabled"
    static let directoryPathUserDefaultsKey = "preferencesSync.cloud.directoryPath"
    static let deviceIDUserDefaultsKey = "preferencesSync.cloud.deviceID"
    static let generationUserDefaultsKey = "preferencesSync.cloud.generation"
    static let lastSyncedAtUserDefaultsKey = "preferencesSync.cloud.lastSyncedAt"
    static let consumedManualDocumentIDsUserDefaultsKey = "preferencesSync.cloud.consumedManualDocumentIDs"
    static let stateUserDefaultsKey = "preferencesSync.cloud.folderStates"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let debounceDelay: Duration
    private let readSnapshot: @Sendable (URL) async throws -> Data
    private let writeQueue: DispatchQueue
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
    var isReadyToSync: () -> Bool = { true }

    private var state = CloudPreferencesSyncState()
    private var stateLoadError: Error?
    private var pendingExportTask: Task<Void, Never>?
    private var pendingCheckTask: Task<Void, Never>?
    private var syncTask: Task<Void, Error>?
    private var wantsExport = false
    private var isApplyingExternalSnapshot = false
    private var isTerminating = false
    private var localRevision: UInt64 = 0
    private var syncSession = CloudPreferencesSyncSession()
    private var consumedManualDocumentIDs: Set<String>
    private var incomingSnapshotError: Error?
    private var directorySource: DispatchSourceFileSystemObject?
    private var filePresenter: SyncFolderPresenter?

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        debounceDelay: Duration = .seconds(2),
        writeQueue: DispatchQueue = DispatchQueue(
            label: "app.ggbond.MacTools.CloudPreferencesSyncCoordinator.writer", qos: .utility
        ),
        readSnapshot: @escaping @Sendable (URL) async throws -> Data = { url in
            try await Task.detached(priority: .utility) {
                try PreferencesBackup.readFile(at: url)
            }.value
        }
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.debounceDelay = debounceDelay
        self.writeQueue = writeQueue
        self.readSnapshot = readSnapshot
        let savedID = userDefaults.string(forKey: Self.deviceIDUserDefaultsKey)
        localDeviceID = savedID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        userDefaults.set(localDeviceID, forKey: Self.deviceIDUserDefaultsKey)
        currentGeneration = userDefaults.string(forKey: Self.generationUserDefaultsKey).flatMap(UInt64.init) ?? 0
        let timestamp = userDefaults.double(forKey: Self.lastSyncedAtUserDefaultsKey)
        lastSyncedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        consumedManualDocumentIDs = Set(
            userDefaults.stringArray(forKey: Self.consumedManualDocumentIDsUserDefaultsKey) ?? []
        )
        isEnabled = userDefaults.bool(forKey: Self.enabledUserDefaultsKey)
        if let path = userDefaults.string(forKey: Self.directoryPathUserDefaultsKey), !path.isEmpty {
            syncDirectoryURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        loadState()
        updateStatus()
    }

    isolated deinit {
        syncSession.cancel()
        stopObservingDirectory()
        pendingExportTask?.cancel()
        pendingCheckTask?.cancel()
        syncTask?.cancel()
    }

    func start() {
        guard isReadyToSync(), isEnabled, !isTerminating else { return }
        startObservingDirectory()
        scheduleExport(immediately: true)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        invalidateSession()
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledUserDefaultsKey)
        if enabled { start() } else { stopObservingDirectory() }
        updateStatus()
    }

    func setSyncDirectoryURL(_ url: URL?) {
        guard syncDirectoryURL != url else { return }
        invalidateSession()
        stopObservingDirectory()
        syncDirectoryURL = url
        incomingSnapshotError = nil
        currentGeneration = 0
        lastSyncedAt = nil
        userDefaults.set(url?.path, forKey: Self.directoryPathUserDefaultsKey)
        loadState()
        directoryURLHandler?(url)
        start()
        updateStatus()
    }

    func committedPreferencesDidChange() {
        guard isReadyToSync(), !isApplyingExternalSnapshot, !isTerminating,
              syncDirectoryURL != nil else { return }
        localRevision &+= 1
        do {
            try captureLocalChanges(isCommit: true)
            if isEnabled { scheduleExport() }
            updateStatus()
        } catch { handleError(error) }
    }

    /// Quitting never writes to the shared folder. The next launch reconciles the
    /// durable pending edit against its shared base before attempting publication.
    func flushPendingExportBeforeTermination() {
        guard isReadyToSync() else { return }
        if !isApplyingExternalSnapshot {
            do { try captureLocalChanges() } catch { handleError(error) }
        }
        isTerminating = true
        invalidateSession()
        stopObservingDirectory()
    }

    func syncNow() async throws {
        pendingExportTask?.cancel()
        pendingExportTask = nil
        pendingCheckTask?.cancel()
        pendingCheckTask = nil
        do { try await synchronize(publish: true) }
        catch {
            handleError(error)
            throw error
        }
    }

    func checkForIncomingSnapshots() async {
        do { try await synchronize(publish: false) }
        catch is CancellationError { return }
        catch { handleError(error) }
    }

    func resolveConflict(_ choice: CloudPreferencesConflictChoice) async throws {
        guard isEnabled, isReadyToSync(), !isTerminating else { return }
        // Serialize resolution with an observer or an in-flight write.
        if let syncTask { try await syncTask.value }
        guard let conflict = state.conflict, let directory = syncDirectoryURL else { return }
        let session = syncSession
        let observation = try await readSharedFolder(directory)
        try session.checkCancellation()
        try captureLocalChanges()
        guard let shared = observation.snapshot else { throw CloudPreferencesSyncError.snapshotMissing }
        guard sameDocument(shared, conflict.shared) else {
            // The offered version changed while the choice was open. Retain the
            // previous pair and ask again instead of choosing an unseen revision.
            state.lastResolvedConflict = state.conflict
            try recordConflict(shared)
            return
        }
        state.lastResolvedConflict = state.conflict
        switch choice {
        case .shared:
            try applyShared(shared)
        case .local:
            state.shared = shared
            state.conflict = nil
            state.pending = currentBackup()
            state.needsPublication = true
            currentGeneration = max(currentGeneration, shared.generation)
            try persistState()
        }
        try await synchronize(publish: true)
    }

    private func scheduleExport(immediately: Bool = false) {
        guard !isTerminating else { return }
        pendingExportTask?.cancel()
        pendingExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediately, self.debounceDelay > .zero { try await Task.sleep(for: self.debounceDelay) }
                try Task.checkCancellation()
                try await self.synchronize(publish: true)
            } catch is CancellationError { return }
            catch { self.handleError(error) }
        }
    }

    private func invalidateSession() {
        syncSession.cancel()
        syncSession = CloudPreferencesSyncSession()
        pendingExportTask?.cancel()
        pendingExportTask = nil
        pendingCheckTask?.cancel()
        pendingCheckTask = nil
        wantsExport = false
    }

    private func synchronize(publish: Bool) async throws {
        guard isReadyToSync(), isEnabled, syncDirectoryURL != nil, !isTerminating else {
            updateStatus()
            return
        }
        wantsExport = wantsExport || publish
        if let syncTask {
            try await syncTask.value
            return
        }
        let task = Task { @MainActor in
            defer { self.syncTask = nil }
            var retries = 0
            repeat {
                let shouldPublish = self.wantsExport
                self.wantsExport = false
                let session = self.syncSession
                do {
                    try await self.synchronizeOnce(publish: shouldPublish)
                } catch CloudPreferencesSyncError.sharedFileChanged {
                    retries += 1
                    guard retries < 3 else { throw CloudPreferencesSyncError.sharedFileChanged }
                    self.wantsExport = true
                } catch is CancellationError {
                    guard session !== self.syncSession, self.isEnabled, !self.isTerminating else { return }
                    self.wantsExport = true
                }
            } while self.wantsExport && self.state.conflict == nil && self.isEnabled && !self.isTerminating
        }
        syncTask = task
        try await task.value
    }

    private func synchronizeOnce(publish: Bool) async throws {
        if let stateLoadError { throw stateLoadError }
        guard let directory = syncDirectoryURL else { return }
        let session = syncSession
        try captureLocalChanges()
        // A fresh observation replaces previous parsing and availability errors.
        incomingSnapshotError = nil
        let observation = try await readSharedFolder(directory)
        try session.checkCancellation()
        try captureLocalChanges()
        if let snapshot = observation.snapshot {
            try reconcile(snapshot)
            // A legacy persisted generation may be newer than the only visible
            // shared file. Seeing that stale file does not authorize an initial export.
            if state.shared == nil, state.conflict == nil {
                updateStatus()
                return
            }
        } else if state.shared != nil || currentGeneration > 0 {
            throw CloudPreferencesSyncError.snapshotMissing
        }
        guard state.conflict == nil else {
            updateStatus()
            return
        }
        guard publish || state.needsPublication else {
            updateStatus()
            return
        }
        guard state.pending != nil || state.needsPublication || state.shared == nil else {
            updateStatus()
            return
        }
        updateStatus(to: .syncing)
        try session.checkCancellation()
        guard let backup = currentBackup() else { throw CocoaError(.fileReadUnknown) }
        let revision = localRevision
        guard currentGeneration < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
        let snapshot = CloudPreferencesSnapshot(
            generation: currentGeneration + 1,
            deviceID: localDeviceID,
            deviceName: Host.current().localizedName ?? "Mac",
            parentDocumentID: state.shared?.documentID,
            backup: backup
        )
        let data = try snapshot.encodedJSON()
        let destination = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try Self.writeSnapshot(data, to: destination, replacing: observation.canonicalData, session: session)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        try session.checkCancellation()
        // Compare subsequent reads with the representation actually written,
        // including the archive's legacy date encoding inside backup records.
        state.shared = try CloudPreferencesSnapshot.decodeJSON(data)
        state.localBaseline = backup
        state.pending = nil
        state.needsPublication = false
        currentGeneration = snapshot.generation
        lastSyncedAt = snapshot.timestamp
        try captureLocalChanges()
        try persistState()
        // Edits committed while the disk write was suspended need a new read first.
        if localRevision != revision, state.pending != nil { wantsExport = true }
        updateStatus()
    }

    private func reconcile(_ snapshot: CloudPreferencesSnapshot) throws {
        let incoming = Self.filterMachineSpecificPreferences(snapshot.backup)
        if state.conflict != nil {
            // Leave the saved pair intact until an explicit choice; resolution
            // re-reads the file to avoid applying an unseen shared revision.
            return
        }
        if let base = state.shared {
            if sameDocument(snapshot, base) { return }
            let isSibling = snapshot.isCloudSnapshot && base.isCloudSnapshot
                && snapshot.deviceID != base.deviceID
                && (snapshot.generation == base.generation
                    || (snapshot.syncMetadata?.parentDocumentID != nil
                        && snapshot.syncMetadata?.parentDocumentID == base.syncMetadata?.parentDocumentID))
            if Self.filterMachineSpecificPreferences(base.backup).hasSameMeaningfulContent(as: incoming) {
                state.shared = snapshot
                currentGeneration = max(currentGeneration, snapshot.generation)
                try persistState()
                return
            }
            if let current = currentBackup(), current.hasSameMeaningfulContent(as: incoming) {
                try accept(snapshot)
            } else if state.pending != nil || state.needsPublication || isSibling
                || (snapshot.isCloudSnapshot && snapshot.generation < base.generation) {
                // An offline Mac can publish from an older base. A smaller
                // generation does not prove that its different content is stale.
                try recordConflict(snapshot)
            } else {
                try applyShared(snapshot)
            }
        } else if snapshot.isCloudSnapshot, snapshot.generation < currentGeneration {
            // Legacy clients persisted only a counter, so ancestry is unknown.
            try recordConflict(snapshot)
        } else if state.pending != nil {
            if currentBackup()?.hasSameMeaningfulContent(as: incoming) == true {
                try accept(snapshot)
            } else { try recordConflict(snapshot) }
        } else if snapshot.deviceID == localDeviceID {
            // An echo after relaunch establishes the baseline without restoring it.
            try accept(snapshot)
        } else {
            try applyShared(snapshot)
        }
    }

    private func applyShared(_ snapshot: CloudPreferencesSnapshot) throws {
        isApplyingExternalSnapshot = true
        defer { isApplyingExternalSnapshot = false }
        try importHandler?(Self.filterMachineSpecificPreferences(snapshot.backup))
        try accept(snapshot)
    }

    private func accept(_ snapshot: CloudPreferencesSnapshot) throws {
        state.shared = snapshot
        state.localBaseline = currentBackup() ?? Self.filterMachineSpecificPreferences(snapshot.backup)
        state.pending = nil
        state.conflict = nil
        state.needsPublication = !snapshot.isCloudSnapshot
        currentGeneration = max(currentGeneration, snapshot.generation)
        lastSyncedAt = snapshot.timestamp
        if !snapshot.isCloudSnapshot {
            consumedManualDocumentIDs.insert(snapshot.documentID)
            userDefaults.set(Array(consumedManualDocumentIDs.sorted().suffix(32)),
                             forKey: Self.consumedManualDocumentIDsUserDefaultsKey)
        }
        try persistState()
    }

    private func recordConflict(_ snapshot: CloudPreferencesSnapshot) throws {
        guard let local = currentBackup() else { throw CocoaError(.fileReadUnknown) }
        state.conflict = CloudPreferencesConflict(local: local, shared: snapshot)
        state.pending = local
        try persistState()
        updateStatus()
    }

    private func sameDocument(_ lhs: CloudPreferencesSnapshot, _ rhs: CloudPreferencesSnapshot) -> Bool {
        lhs.documentID == rhs.documentID && lhs.backup.hasSameMeaningfulContent(as: rhs.backup)
    }

    private func currentBackup() -> PreferencesBackup? {
        snapshotProvider?().map(Self.filterMachineSpecificPreferences)
    }

    private func captureLocalChanges(isCommit: Bool = false) throws {
        if let stateLoadError { throw stateLoadError }
        guard let current = currentBackup(), syncDirectoryURL != nil else { return }
        if let baseline = state.localBaseline {
            state.pending = baseline.hasSameMeaningfulContent(as: current) ? nil : current
        } else if isCommit || state.pending != nil {
            state.pending = current
        } else { state.localBaseline = current }
        if state.conflict != nil { state.conflict?.local = current }
        try persistState()
    }

    private func loadState() {
        state = CloudPreferencesSyncState()
        stateLoadError = nil
        guard let path = syncDirectoryURL?.path,
              let states = userDefaults.dictionary(forKey: Self.stateUserDefaultsKey),
              let data = states[path] as? Data else { return }
        do {
            state = try JSONDecoder().decode(CloudPreferencesSyncState.self, from: data)
            currentGeneration = state.shared?.generation ?? 0
            lastSyncedAt = state.shared?.timestamp
        } catch { stateLoadError = error }
    }

    private func persistState() throws {
        guard let path = syncDirectoryURL?.path else { return }
        var states = userDefaults.dictionary(forKey: Self.stateUserDefaultsKey) ?? [:]
        states[path] = try JSONEncoder().encode(state)
        userDefaults.set(states, forKey: Self.stateUserDefaultsKey)
        userDefaults.set(String(currentGeneration), forKey: Self.generationUserDefaultsKey)
        userDefaults.set(lastSyncedAt?.timeIntervalSince1970, forKey: Self.lastSyncedAtUserDefaultsKey)
    }

    private struct FolderObservation {
        let snapshot: CloudPreferencesSnapshot?
        let canonicalData: Data?
    }

    private func readSharedFolder(_ directory: URL) async throws -> FolderObservation {
        // Listing errors must not be interpreted as an empty folder. We never
        // recreate an unavailable provider folder as a side effect of retrying.
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let candidates = try urls.compactMap { url -> (URL, Date, Bool)? in
            let canonical = url.lastPathComponent == CloudPreferencesSnapshot.defaultFileName
            let manual = url.lastPathComponent.hasPrefix("MacTools Preferences ") && url.pathExtension.lowercased() == "json"
            guard canonical || manual else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
            return (url, values.addedToDirectoryDate ?? values.contentModificationDate ?? .distantPast, canonical)
        }.sorted {
            $0.1 == $1.1 ? $0.2 && !$1.2 : $0.1 > $1.1
        }
        let canonicalURL = directory.appendingPathComponent(CloudPreferencesSnapshot.defaultFileName)
        let canonicalData = candidates.contains(where: { $0.2 }) ? try await readSnapshot(canonicalURL) : nil
        for candidate in candidates {
            let data: Data
            if candidate.2, let canonicalData { data = canonicalData }
            else { data = try await readSnapshot(candidate.0) }
            let snapshot = try CloudPreferencesSnapshot.decodeCompatibleJSON(data)
            if !snapshot.isCloudSnapshot, consumedManualDocumentIDs.contains(snapshot.documentID),
               snapshot.documentID != state.shared?.documentID { continue }
            if !snapshot.isCloudSnapshot, consumedManualDocumentIDs.contains(snapshot.documentID),
               canonicalData != nil, !candidate.2 { continue }
            return FolderObservation(snapshot: snapshot, canonicalData: canonicalData)
        }
        return FolderObservation(snapshot: nil, canonicalData: canonicalData)
    }

    nonisolated private static func writeSnapshot(
        _ data: Data, to url: URL, replacing expected: Data?, session: CloudPreferencesSyncSession
    ) throws {
        try session.checkCancellation()
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try session.checkCancellation()
                let current: Data?
                do { current = try PreferencesBackup.readFile(at: coordinatedURL) }
                catch CocoaError.fileReadNoSuchFile { current = nil }
                catch CocoaError.fileNoSuchFile { current = nil }
                guard current == expected else { throw CloudPreferencesSyncError.sharedFileChanged }
                try session.checkCancellation()
                try data.write(to: coordinatedURL, options: .atomic)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func startObservingDirectory() {
        stopObservingDirectory()
        guard let url = syncDirectoryURL else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .attrib, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleIncomingSnapshotCheck() }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
        let presenter = SyncFolderPresenter(url: url) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleIncomingSnapshotCheck() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        filePresenter = presenter
    }

    private func stopObservingDirectory() {
        if let filePresenter { NSFileCoordinator.removeFilePresenter(filePresenter) }
        filePresenter = nil
        directorySource?.cancel()
        directorySource = nil
    }

    private func scheduleIncomingSnapshotCheck() {
        guard isEnabled, !isTerminating else { return }
        pendingCheckTask?.cancel()
        pendingCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                await self?.checkForIncomingSnapshots()
            } catch { return }
        }
    }

    private func updateStatus(to explicit: CloudPreferencesSyncStatus? = nil) {
        defer { statusHandler?(status) }
        if let explicit { status = explicit; return }
        guard isEnabled else { status = .offline(reason: .disabled); return }
        guard let directory = syncDirectoryURL else { status = .offline(reason: .folderNotConfigured); return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            status = .offline(reason: .folderNotFound)
            return
        }
        if let error = stateLoadError ?? incomingSnapshotError {
            if error as? CloudPreferencesSyncError == .snapshotMissing { status = .offline(reason: .snapshotMissing) }
            else { status = .error(message: error.localizedDescription) }
        } else if let conflict = state.conflict {
            status = .conflict(deviceName: conflict.shared.deviceName)
        } else if state.pending != nil || state.needsPublication {
            status = .pending
        } else { status = .synced(lastSyncedAt: lastSyncedAt) }
    }

    private func handleError(_ error: Error) {
        incomingSnapshotError = error
        updateStatus()
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

        let workflows = backup.workflows?.map { workflow in
            var sanitized = workflow
            sanitized.steps = workflow.steps.filter { step in
                !isMachineSpecificActionReference(step.reference)
            }
            return sanitized
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

    static func preservingMachineSpecificPluginPreferences(incoming: Data, local: Data, pluginID: String) -> Data {
        guard let localValue = try? JSONSerialization.jsonObject(with: local),
              let incomingValue = try? JSONSerialization.jsonObject(with: incoming),
              let filteredData = sanitizePluginPreferenceData(pluginID: pluginID, data: local),
              let filteredValue = try? JSONSerialization.jsonObject(with: filteredData) else { return incoming }
        func merge(_ local: Any, _ filtered: Any, _ incoming: Any) -> Any {
            guard (local as? NSObject)?.isEqual(filtered) != true else { return incoming }
            if let local = local as? [String: Any], let filtered = filtered as? [String: Any],
               var incoming = incoming as? [String: Any] {
                for (key, value) in local {
                    if let portable = filtered[key] {
                        if let replacement = incoming[key] { incoming[key] = merge(value, portable, replacement) }
                        else if (value as? NSObject)?.isEqual(portable) != true { incoming[key] = value }
                    } else { incoming[key] = value }
                }
                return incoming
            }
            // Array entries may contain hardware identities. Preserve the local
            // collection rather than matching devices by an unstable array index.
            return local
        }
        var merged = merge(localValue, filteredValue, incomingValue)
        if pluginID == "fan-control", let local = localValue as? [String: Any],
           var values = merged as? [String: Any], let activeID = local["activePresetID"] as? String,
           let presets = local["customPresets"] as? [[String: Any]],
           let activePreset = presets.first(where: { $0["id"] as? String == activeID }) {
            var incomingPresets = values["customPresets"] as? [[String: Any]] ?? []
            incomingPresets.removeAll { $0["id"] as? String == activeID }
            incomingPresets.append(activePreset)
            values["customPresets"] = incomingPresets
            merged = values
        }
        return (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? incoming
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
