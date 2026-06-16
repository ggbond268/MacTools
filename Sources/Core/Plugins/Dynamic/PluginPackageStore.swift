import Foundation
import MacToolsPluginKit

struct PluginPackageRecord: Identifiable, Equatable {
    enum State: Equatable {
        case enabled
        case disabled
        case incompatible(String)
        case failed(String)
    }

    let id: String
    let manifest: PluginPackageManifest
    let packageURL: URL
    let bundleURL: URL
    let state: State
    let requiresRestartToFullyUnload: Bool
}

enum PluginPackageStoreError: LocalizedError {
    case packageNotFound(String)
    case packageAlreadyInstalled(String)
    case invalidPackage(URL)
    case installFailed(String)
    case removeFailed(String)

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
        }
    }
}

@MainActor
final class PluginPackageStore {
    private enum DefaultsKey {
        static let disabledPluginIDs = "plugins.dynamic.disabledPluginIDs"
    }

    let rootDirectory: URL
    let installedDirectory: URL
    let stagingDirectory: URL
    let dataDirectory: URL
    let cacheDirectory: URL
    let temporaryDirectory: URL

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    let hostVersion: String
    private let trustValidator: PluginTrustValidating
    private let quarantineInspector: PluginQuarantineInspecting
    private var pendingRestartPluginIDs: Set<String> = []

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        hostVersion: String = AppMetadata.shortVersion ?? "0",
        trustValidator: PluginTrustValidating = SameTeamPluginTrustValidator(),
        quarantineInspector: PluginQuarantineInspecting = PluginQuarantineInspector()
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.hostVersion = hostVersion
        self.trustValidator = trustValidator
        self.quarantineInspector = quarantineInspector

        let root = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.rootDirectory = root
        self.installedDirectory = root.appendingPathComponent("Installed", isDirectory: true)
        self.stagingDirectory = root.appendingPathComponent("Staging", isDirectory: true)
        self.dataDirectory = root.appendingPathComponent("Data", isDirectory: true)
        self.cacheDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        self.temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)

        createBaseDirectories()
    }

    func installedRecords() -> [PluginPackageRecord] {
        createBaseDirectories()

        let packageURLs = (try? fileManager.contentsOfDirectory(
            at: installedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return packageURLs
            .filter { $0.pathExtension == "mactoolsplugin" }
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
                        state = disabledPluginIDs.contains(manifest.id) ? .disabled : .enabled
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
                        state: .failed(error.localizedDescription),
                        requiresRestartToFullyUnload: pendingRestartPluginIDs.contains(fallbackID)
                    )
                }
            }
            .sorted { lhs, rhs in
                lhs.manifest.localizedDisplayName.localizedCompare(rhs.manifest.localizedDisplayName) == .orderedAscending
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
        let wasDisabled = disabledPluginIDs.contains(manifest.id)

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

            // Browser-downloaded zips carry com.apple.quarantine and ditto/copy propagate
            // it onto every file; Gatekeeper then rejects dlopen of the non-notarized
            // bundle in a hardened host. Strip the attribute from the staged copy, but
            // only after the staged bundle passed trust validation — a bundle failing
            // validation keeps its quarantine and the install fails closed.
            let quarantinedItems = try quarantineInspector.quarantinedItemURLs(in: stagingURL)
            if !quarantinedItems.isEmpty {
                try trustValidator.validatePluginBundle(at: stagedBundleURL)
                try quarantineInspector.stripQuarantine(at: stagingURL)
                AppLog.dynamicPlugins.info(
                    "Stripped quarantine from \(quarantinedItems.count, privacy: .public) item(s) in staged package \(stagedManifest.id, privacy: .public)"
                )
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

        if !hadExistingPackage || !wasDisabled {
            setEnabled(true, for: manifest.id)
        }
        clearPendingRestart(pluginID: manifest.id)

        guard let record = installedRecords().first(where: { $0.id == manifest.id }) else {
            throw PluginPackageStoreError.installFailed(AppL10n.plugins(
                "plugin.error.store.recordMissingAfterInstall",
                defaultValue: "安装完成后无法读取插件记录。"
            ))
        }

        return record
    }

    func updatePackage(from sourceURL: URL) throws -> PluginPackageRecord {
        try installPackage(from: sourceURL, replaceExisting: true)
    }

    func setEnabled(_ isEnabled: Bool, for pluginID: String) {
        var ids = disabledPluginIDs

        if isEnabled {
            ids.remove(pluginID)
            clearPendingRestart(pluginID: pluginID)
        } else {
            ids.insert(pluginID)
            markPendingRestart(pluginID: pluginID)
        }

        disabledPluginIDs = ids
    }

    func markRequiresRestartToFullyUnload(pluginID: String) {
        markPendingRestart(pluginID: pluginID)
    }

    func uninstall(pluginID: String, removeData: Bool) throws {
        setEnabled(false, for: pluginID)
        try removePackageFiles(pluginID: pluginID)
        markPendingRestart(pluginID: pluginID)

        if removeData {
            try? fileManager.removeItem(at: dataDirectory.appendingPathComponent(pluginID, isDirectory: true))
            try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(pluginID, isDirectory: true))
            try? fileManager.removeItem(at: temporaryDirectory.appendingPathComponent(pluginID, isDirectory: true))
            UserDefaultsPluginStorage.removeAllValues(pluginID: pluginID, userDefaults: userDefaults)
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

    private var disabledPluginIDs: Set<String> {
        get {
            Set(userDefaults.stringArray(forKey: DefaultsKey.disabledPluginIDs) ?? [])
        }
        set {
            userDefaults.set(Array(newValue).sorted(), forKey: DefaultsKey.disabledPluginIDs)
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
