import Foundation
import MacToolsPluginKit
import Security

struct PluginPackageRecord: Identifiable, Equatable {
    enum State: Equatable {
        case installed
        case incompatible(String)
        case failed(String)
    }

    let id: String
    let manifest: PluginPackageManifest
    let packageURL: URL
    let bundleURL: URL
    let installedAt: Date
    let state: State
    let requiresRestartToFullyUnload: Bool
}

enum PluginPackageStoreError: LocalizedError {
    case packageNotFound(String)
    case packageAlreadyInstalled(String)
    case invalidPackage(URL)
    case installFailed(String)
    case removeFailed(String)
    case privateDataRemovalFailed(String)
    case migrationStatePersistenceFailed

    var errorDescription: String? {
        switch self {
        case let .packageNotFound(id):
            return AppL10n.pluginsFormat("plugin.error.store.notFoundFormat", defaultValue: "未找到插件：%@", id)
        case let .packageAlreadyInstalled(id):
            return AppL10n.pluginsFormat("plugin.error.store.alreadyInstalledFormat", defaultValue: "插件已安装：%@", id)
        case let .invalidPackage(url):
            return AppL10n.pluginsFormat("plugin.error.store.invalidPackageFormat", defaultValue: "插件包无效：%@", url.path)
        case let .installFailed(reason):
            return AppL10n.pluginsFormat("plugin.error.store.installFailedFormat", defaultValue: "插件安装失败：%@", reason)
        case let .removeFailed(reason):
            return AppL10n.pluginsFormat("plugin.error.store.removeFailedFormat", defaultValue: "插件移除失败：%@", reason)
        case let .privateDataRemovalFailed(reason):
            return AppL10n.pluginsFormat(
                "plugin.error.store.privateDataRemovalFailedFormat",
                defaultValue: "无法移除插件私密数据：%@",
                reason
            )
        case .migrationStatePersistenceFailed:
            return AppL10n.plugins(
                "plugin.error.store.migrationStatePersistenceFailed",
                defaultValue: "无法保存插件迁移状态，未移除插件。"
            )
        }
    }
}

@MainActor
final class PluginPackageStore {
    private enum DefaultsKey {
        // Keep the previous key so upgrades can safely discover packages that
        // were disabled before the installed/uninstalled-only model.
        static let legacyDisabledPluginIDs = "plugins.dynamic.disabledPluginIDs"
        static let installedAtByPluginID = "plugins.dynamic.installedAtByPluginID"
    }

    let rootDirectory: URL
    let installedDirectory: URL
    let stagingDirectory: URL
    let dataDirectory: URL
    let cacheDirectory: URL
    let temporaryDirectory: URL

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let synchronizeUserDefaults: (UserDefaults) -> Bool
    private let privateDataDirectoryRemover: (URL) throws -> Void
    private let privateDataKeyRemover: (String) throws -> Void
    private let now: () -> Date
    let hostVersion: String
    private var pendingRestartPluginIDs: Set<String> = []

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        synchronizeUserDefaults: @escaping (UserDefaults) -> Bool = { $0.synchronize() },
        privateDataDirectoryRemover: ((URL) throws -> Void)? = nil,
        privateDataKeyRemover: ((String) throws -> Void)? = nil,
        now: @escaping () -> Date = { Date() },
        hostVersion: String = AppMetadata.shortVersion ?? "0"
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.synchronizeUserDefaults = synchronizeUserDefaults
        self.privateDataDirectoryRemover = privateDataDirectoryRemover ?? { url in
            try fileManager.removeItem(at: url)
        }
        self.privateDataKeyRemover = privateDataKeyRemover ?? Self.removePrivateDataKey
        self.now = now
        self.hostVersion = hostVersion

        let root = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.rootDirectory = root
        self.installedDirectory = root.appendingPathComponent("Installed", isDirectory: true)
        self.stagingDirectory = root.appendingPathComponent("Staging", isDirectory: true)
        self.dataDirectory = root.appendingPathComponent("Data", isDirectory: true)
        self.cacheDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        self.temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)

        createBaseDirectories()
        recoverFeatureExtractionSourceUninstallIfNeeded()
        reconcileCompletedFeatureExtractionJournalIfNeeded()
    }

    func installedRecords() -> [PluginPackageRecord] {
        createBaseDirectories()
        recoverFeatureExtractionSourceUninstallIfNeeded()
        reconcileCompletedFeatureExtractionJournalIfNeeded()

        let pendingSourceUninstallID = featureExtractionSourceUninstallIsPending()
            ? PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick.sourcePluginID
            : nil

        let packageURLs = (try? fileManager.contentsOfDirectory(
            at: installedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let originalInstalledAtTimestamps = installedAtTimestamps()
        var installedAtTimestamps = originalInstalledAtTimestamps

        func installedAt(pluginID: String, packageURL: URL) -> Date {
            if let timestamp = installedAtTimestamps[pluginID] {
                return Date(timeIntervalSince1970: timestamp)
            }

            let creationDate = try? packageURL.resourceValues(
                forKeys: [.creationDateKey]
            ).creationDate
            let date = creationDate ?? now()
            installedAtTimestamps[pluginID] = date.timeIntervalSince1970
            return date
        }

        let records = packageURLs
            .filter { $0.pathExtension == "mactoolsplugin" }
            .filter { packageURL in
                packageURL.deletingPathExtension().lastPathComponent != pendingSourceUninstallID
            }
            .compactMap { packageURL in
                do {
                    let manifest = try PluginPackageManifestLoader.decode(from: packageURL)
                    try PluginPackageManifestLoader.validatePackageIdentity(manifest)
                    let bundleURL = packageURL.appendingPathComponent(manifest.bundleRelativePath)
                    let state: PluginPackageRecord.State

                    if manifest.pluginKitVersion != PluginPackageManifestLoader.supportedPluginKitVersion {
                        state = .incompatible(
                            AppL10n.pluginsFormat(
                                "plugin.error.store.installedSDKIncompatibleFormat",
                                defaultValue: "插件 SDK 版本不兼容，已安装版本为 %d，当前支持版本为 %d。请更新插件。",
                                manifest.pluginKitVersion,
                                PluginPackageManifestLoader.supportedPluginKitVersion
                            )
                        )
                    } else if !PluginVersionComparator.isVersion(hostVersion, atLeast: manifest.minHostVersion) {
                        state = .incompatible(
                            AppL10n.pluginsFormat(
                                "plugin.error.store.installedHostIncompatibleFormat",
                                defaultValue: "插件需要 MacTools %@ 或更高版本，当前版本为 %@。",
                                manifest.minHostVersion,
                                hostVersion
                            )
                        )
                    } else if fileManager.fileExists(atPath: bundleURL.path) {
                        state = .installed
                    } else {
                        state = .failed(AppL10n.pluginsFormat(
                            "plugin.error.store.bundleMissingFormat",
                            defaultValue: "插件入口不存在：%@",
                            bundleURL.path
                        ))
                    }

                    return PluginPackageRecord(
                        id: manifest.id,
                        manifest: manifest,
                        packageURL: packageURL,
                        bundleURL: bundleURL,
                        installedAt: installedAt(pluginID: manifest.id, packageURL: packageURL),
                        state: state,
                        requiresRestartToFullyUnload: pendingRestartPluginIDs.contains(manifest.id)
                    )
                } catch {
                    let fallbackID = packageURL.deletingPathExtension().lastPathComponent
                    return PluginPackageRecord(
                        id: fallbackID,
                        manifest: PluginPackageManifest(
                            id: fallbackID,
                            displayName: fallbackID,
                            version: "0",
                            minHostVersion: "0",
                            bundleRelativePath: ""
                        ),
                        packageURL: packageURL,
                        bundleURL: packageURL,
                        installedAt: installedAt(pluginID: fallbackID, packageURL: packageURL),
                        state: .failed(error.localizedDescription),
                        requiresRestartToFullyUnload: pendingRestartPluginIDs.contains(fallbackID)
                    )
                }
            }
        if installedAtTimestamps != originalInstalledAtTimestamps {
            userDefaults.set(installedAtTimestamps, forKey: DefaultsKey.installedAtByPluginID)
        }

        return records.sorted { lhs, rhs in
            lhs.manifest.localizedDisplayName.localizedCompare(
                rhs.manifest.localizedDisplayName
            ) == .orderedAscending
        }
    }

    func featureExtractionMigrationIsInProgress() -> Bool {
        featureExtractionMigrationHasPersistedJournal()
            || featureExtractionSourceUninstallIsPending()
            || featureExtractionMigrationHasUnsafeInstalledState()
    }

    func featureExtractionSourceUninstallIsPending() -> Bool {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        return userDefaults.object(forKey: policy.sourceUninstallIntentKey) != nil
    }

    func featureExtractionMigrationHasPersistedJournal() -> Bool {
        reconcileCompletedFeatureExtractionJournalIfNeeded()
        return userDefaults.bool(
            forKey: PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick.transactionJournalKey
        )
    }

    func featureExtractionMigrationIsComplete() -> Bool {
        userDefaults.bool(
            forKey: PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick.completionKey
        )
    }

    func featureExtractionMigrationHasUnsafeInstalledState() -> Bool {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        guard userDefaults.object(forKey: policy.completionKey) == nil else {
            return false
        }

        let installedRecordsByID = Dictionary(
            installedRecords().compactMap { record -> (String, PluginPackageRecord)? in
                guard case .installed = record.state else { return nil }
                return (record.id, record)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        guard installedRecordsByID[policy.sourcePluginID] != nil,
              let destination = installedRecordsByID[policy.destinationPluginID],
              PluginVersionComparator.isVersion(
                  destination.manifest.version,
                  atLeast: policy.minimumDestinationVersion
              )
        else {
            return false
        }
        return true
    }

    func removePluginPreference(pluginID: String, key: String) {
        userDefaults.removeObject(forKey: "plugin.\(pluginID).\(key)")
    }

    func snapshotPluginPreferences(pluginID: String) -> [String: Any] {
        let prefix = "plugin.\(pluginID)."
        return userDefaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(prefix)
        }
    }

    func restorePluginPreferences(_ snapshot: [String: Any], pluginID: String) {
        UserDefaultsPluginStorage.removeAllValues(pluginID: pluginID, userDefaults: userDefaults)
        for (key, value) in snapshot {
            userDefaults.set(value, forKey: key)
        }
    }

    func installPackage(from sourceURL: URL, replaceExisting: Bool = false) throws -> PluginPackageRecord {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PluginPackageStoreError.invalidPackage(sourceURL)
        }

        let manifest = try PluginPackageManifestLoader.load(from: sourceURL, hostVersion: hostVersion)
        let destinationURL = installedDirectory
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let stagingURL = stagingDirectory
            .appendingPathComponent("\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let backupURL = stagingDirectory
            .appendingPathComponent("\(manifest.id)-backup-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let hadExistingPackage = fileManager.fileExists(atPath: destinationURL.path)

        if hadExistingPackage {
            guard replaceExisting else {
                throw PluginPackageStoreError.packageAlreadyInstalled(manifest.id)
            }
        }

        do {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }

            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            let stagedManifest = try PluginPackageManifestLoader.load(
                from: stagingURL,
                hostVersion: hostVersion
            )
            let stagedBundleURL = stagingURL.appendingPathComponent(stagedManifest.bundleRelativePath)

            guard fileManager.fileExists(atPath: stagedBundleURL.path) else {
                throw PluginPackageStoreError.invalidPackage(stagingURL)
            }

            if hadExistingPackage {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
            }

            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if hadExistingPackage,
               !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            } else {
                try? fileManager.removeItem(at: backupURL)
            }
            throw PluginPackageStoreError.installFailed(error.localizedDescription)
        }

        clearPendingRestart(pluginID: manifest.id)
        if !hadExistingPackage {
            recordFirstInstalledAt(pluginID: manifest.id, date: now())
        }

        guard let record = installedRecords().first(where: { $0.id == manifest.id }) else {
            throw PluginPackageStoreError.installFailed(AppL10n.plugins(
                "plugin.error.store.recordMissingAfterInstall",
                defaultValue: "安装完成后无法读取插件记录。"
            ))
        }

        return record
    }

    func updatePackage(from sourceURL: URL) throws -> PluginPackageRecord {
        let manifest = try PluginPackageManifestLoader.load(
            from: sourceURL,
            hostVersion: hostVersion
        )
        guard installedRecords().contains(where: { $0.id == manifest.id }) else {
            throw PluginPackageStoreError.packageNotFound(manifest.id)
        }

        return try installPackage(from: sourceURL, replaceExisting: true)
    }

    /// Reads the old global hidden marker so the host can migrate it into
    /// Dashboard and Feature Panel visibility before packages load.
    ///
    /// The host clears this marker only after the display-preferences store has
    /// durably accepted it. That preserves the migration across a temporary
    /// downgrade or a future preferences payload this version cannot decode.
    func legacyHiddenPluginIDs() -> Set<String> {
        Set(userDefaults.stringArray(forKey: DefaultsKey.legacyDisabledPluginIDs) ?? [])
    }

    func clearLegacyHiddenPluginIDs() {
        userDefaults.removeObject(forKey: DefaultsKey.legacyDisabledPluginIDs)
    }

    func markRequiresRestartToFullyUnload(pluginID: String) {
        markPendingRestart(pluginID: pluginID)
    }

    func uninstall(pluginID: String, removeData: Bool) throws {
        guard let record = installedRecords().first(where: { $0.id == pluginID }) else {
            throw PluginPackageStoreError.packageNotFound(pluginID)
        }
        let extractionWasInProgress = featureExtractionMigrationIsInProgress()
        let extractionPolicy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        let requiresDurableSourceUninstallIntent = pluginID == extractionPolicy.sourcePluginID
            && extractionWasInProgress

        if requiresDurableSourceUninstallIntent {
            userDefaults.set(true, forKey: extractionPolicy.sourceUninstallIntentKey)
            userDefaults.set(removeData, forKey: extractionPolicy.sourceUninstallRemoveDataKey)
            guard synchronizeUserDefaults(userDefaults) else {
                userDefaults.removeObject(forKey: extractionPolicy.sourceUninstallIntentKey)
                userDefaults.removeObject(forKey: extractionPolicy.sourceUninstallRemoveDataKey)
                _ = synchronizeUserDefaults(userDefaults)
                throw PluginPackageStoreError.migrationStatePersistenceFailed
            }
        }

        if record.manifest.effectiveUninstallDataPolicy == .removePrivateData {
            try removePrivatePluginData(pluginID: pluginID)
        }

        try removePackageFiles(pluginID: pluginID)
        removeInstalledAt(pluginID: pluginID)
        markPendingRestart(pluginID: pluginID)

        if removeData && record.manifest.effectiveUninstallDataPolicy != .removePrivateData {
            removePluginData(pluginID: pluginID)
        }

        if requiresDurableSourceUninstallIntent {
            finalizeFeatureExtractionSourceUninstall()
        }
    }

    func runtimeContext(for record: PluginPackageRecord) -> PluginRuntimeContext {
        let pluginID = record.id

        let supportURL = dataDirectory.appendingPathComponent(pluginID, isDirectory: true)
        let cacheURL = cacheDirectory.appendingPathComponent(pluginID, isDirectory: true)
        let tempURL = temporaryDirectory.appendingPathComponent(pluginID, isDirectory: true)

        [supportURL, cacheURL, tempURL].forEach { url in
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        return PluginRuntimeContext(
            pluginID: pluginID,
            resourceBundle: Bundle(url: record.bundleURL) ?? .main,
            storage: UserDefaultsPluginStorage(pluginID: pluginID, userDefaults: userDefaults),
            supportDirectory: supportURL,
            cacheDirectory: cacheURL,
            temporaryDirectory: tempURL
        )
    }

    private func removePackageFiles(pluginID: String) throws {
        let packageURL = installedDirectory
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")

        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw PluginPackageStoreError.packageNotFound(pluginID)
        }

        do {
            try fileManager.removeItem(at: packageURL)
        } catch {
            throw PluginPackageStoreError.removeFailed(error.localizedDescription)
        }
    }

    private func recoverFeatureExtractionSourceUninstallIfNeeded() {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        guard featureExtractionSourceUninstallIsPending() else { return }

        let packageURL = installedDirectory
            .appendingPathComponent(policy.sourcePluginID, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        if fileManager.fileExists(atPath: packageURL.path) {
            do {
                try fileManager.removeItem(at: packageURL)
            } catch {
                // Keep the durable intent and suppress this source from installed records.
                // A later store access or app launch retries the idempotent removal.
                return
            }
        }
        removeInstalledAt(pluginID: policy.sourcePluginID)

        if userDefaults.bool(forKey: policy.sourceUninstallRemoveDataKey) {
            removePluginData(pluginID: policy.sourcePluginID)
        }
        finalizeFeatureExtractionSourceUninstall()
    }

    private func finalizeFeatureExtractionSourceUninstall() {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick

        // Keep the tombstone durable until completion and journal removal are themselves durable.
        // Recovery can therefore distinguish an explicit uninstall from a crashed source update.
        userDefaults.set(true, forKey: policy.completionKey)
        userDefaults.removeObject(forKey: policy.transactionJournalKey)
        guard synchronizeUserDefaults(userDefaults) else { return }

        userDefaults.removeObject(forKey: policy.sourceUninstallIntentKey)
        userDefaults.removeObject(forKey: policy.sourceUninstallRemoveDataKey)
        _ = synchronizeUserDefaults(userDefaults)
    }

    private func reconcileCompletedFeatureExtractionJournalIfNeeded() {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        guard userDefaults.bool(forKey: policy.completionKey),
              userDefaults.object(forKey: policy.transactionJournalKey) != nil
        else {
            return
        }

        // Completion is written and synchronized before the journal is removed. A crash between
        // those steps leaves this safe terminal state, so discard only the stale journal.
        userDefaults.removeObject(forKey: policy.transactionJournalKey)
        _ = synchronizeUserDefaults(userDefaults)
    }

    private func removePluginData(pluginID: String) {
        try? fileManager.removeItem(at: dataDirectory.appendingPathComponent(pluginID, isDirectory: true))
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(pluginID, isDirectory: true))
        try? fileManager.removeItem(at: temporaryDirectory.appendingPathComponent(pluginID, isDirectory: true))
        UserDefaultsPluginStorage.removeAllValues(pluginID: pluginID, userDefaults: userDefaults)
    }

    private func removePrivatePluginData(pluginID: String) throws {
        var firstError: Error?
        let directories = [
            dataDirectory.appendingPathComponent(pluginID, isDirectory: true),
            cacheDirectory.appendingPathComponent(pluginID, isDirectory: true),
            temporaryDirectory.appendingPathComponent(pluginID, isDirectory: true),
        ]
        for directory in directories {
            do {
                try privateDataDirectoryRemover(directory)
            } catch {
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSFileNoSuchFileError {
                    firstError = firstError ?? error
                }
            }
        }
        do {
            try privateDataKeyRemover(pluginID)
        } catch {
            firstError = firstError ?? error
        }
        UserDefaultsPluginStorage.removeAllValues(pluginID: pluginID, userDefaults: userDefaults)
        if let firstError {
            throw PluginPackageStoreError.privateDataRemovalFailed(firstError.localizedDescription)
        }
    }

    private static func removePrivateDataKey(pluginID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PluginPrivateDataKeychainIdentity.service(pluginID: pluginID),
            kSecAttrAccount as String: PluginPrivateDataKeychainIdentity.encryptionKeyAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"]
            )
        }
    }

    private func installedAtTimestamps() -> [String: TimeInterval] {
        userDefaults.dictionary(forKey: DefaultsKey.installedAtByPluginID)?
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
            ?? [:]
    }

    private func recordFirstInstalledAt(pluginID: String, date: Date) {
        var timestamps = installedAtTimestamps()
        guard timestamps[pluginID] == nil else { return }
        timestamps[pluginID] = date.timeIntervalSince1970
        userDefaults.set(timestamps, forKey: DefaultsKey.installedAtByPluginID)
    }

    private func removeInstalledAt(pluginID: String) {
        var timestamps = installedAtTimestamps()
        guard timestamps.removeValue(forKey: pluginID) != nil else { return }
        userDefaults.set(timestamps, forKey: DefaultsKey.installedAtByPluginID)
    }

    private func createBaseDirectories() {
        [
            rootDirectory,
            installedDirectory,
            stagingDirectory,
            dataDirectory,
            cacheDirectory,
            temporaryDirectory
        ].forEach { url in
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func markPendingRestart(pluginID: String) {
        pendingRestartPluginIDs.insert(pluginID)
    }

    private func clearPendingRestart(pluginID: String) {
        pendingRestartPluginIDs.remove(pluginID)
    }

    static func defaultRootDirectory(fileManager: FileManager) -> URL {
        AppStorageScope.applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("Plugins", isDirectory: true)
    }
}
