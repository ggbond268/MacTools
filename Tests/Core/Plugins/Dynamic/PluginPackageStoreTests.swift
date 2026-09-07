import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PluginPackageStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "PluginPackageStoreTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginPackageStoreTests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        temporaryRoot = nil
    }

    func testInstallCopiesPackageIntoInstalledDirectory() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()

        let record = try store.installPackage(from: sourceURL)

        XCTAssertEqual(record.id, "com.example.demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.packageURL.path))
        XCTAssertEqual(store.installedRecords().map(\.id), ["com.example.demo"])
        XCTAssertEqual(store.installedRecords().first?.state, .installed)
    }

    func testReadsLegacyHiddenMarkerUntilMigrationAcknowledgesIt() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        markLegacyDisabled("com.example.demo")

        XCTAssertEqual(store.legacyHiddenPluginIDs(), Set(["com.example.demo"]))
        XCTAssertEqual(store.legacyHiddenPluginIDs(), Set(["com.example.demo"]))
        XCTAssertEqual(store.installedRecords().first?.state, .installed)

        store.clearLegacyHiddenPluginIDs()

        XCTAssertTrue(store.legacyHiddenPluginIDs().isEmpty)
    }

    func testInstallRejectsPreviousPluginKitPackage() throws {
        let sourceURL = try makePackage(
            id: "com.example.demo",
            pluginKitVersion: 1
        )
        let store = makeStore()

        XCTAssertThrowsError(try store.installPackage(from: sourceURL)) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .unsupportedPluginKitVersion(1))
        }
    }

    func testExistingPreviousPluginKitPackageIsMarkedIncompatible() throws {
        let sourceURL = try makePackage(
            id: "com.example.demo",
            pluginKitVersion: 1
        )
        let store = makeStore()
        let installedURL = store.installedDirectory
            .appendingPathComponent("com.example.demo", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        try FileManager.default.copyItem(at: sourceURL, to: installedURL)

        let record = try XCTUnwrap(store.installedRecords().first)

        XCTAssertEqual(
            record.state,
            .incompatible(
                AppL10n.pluginsFormat(
                    "plugin.error.store.installedSDKIncompatibleFormat",
                    defaultValue: "插件 SDK 版本不兼容，已安装版本为 %d，当前支持版本为 %d。请更新插件。",
                    1,
                    PluginPackageManifestLoader.supportedPluginKitVersion
                )
            )
        )
    }

    func testExistingPluginKit4PackageRemainsDiscoverableForVersion5Update() throws {
        let sourceURL = try makePackage(
            id: "com.example.v4",
            pluginKitVersion: 4
        )
        let store = makeStore()
        let installedURL = store.installedDirectory
            .appendingPathComponent("com.example.v4", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        try FileManager.default.copyItem(at: sourceURL, to: installedURL)

        let record = try XCTUnwrap(store.installedRecords().first)

        XCTAssertEqual(record.id, "com.example.v4")
        XCTAssertEqual(record.manifest.pluginKitVersion, 4)
        guard case .incompatible = record.state else {
            return XCTFail("PluginKit v4 package should remain discoverable but incompatible")
        }
    }

    func testExistingV3ManifestRemainsDiscoverableForCatalogUpdate() throws {
        let store = makeStore()
        let installedURL = store.installedDirectory
            .appendingPathComponent("com.example.legacy", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = installedURL.appendingPathComponent("Legacy.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifestData = """
        {
          "id": "com.example.legacy",
          "displayName": "Legacy",
          "version": "3.2.1",
          "minHostVersion": "1.1.6",
          "pluginKitVersion": 3,
          "bundleRelativePath": "Legacy.bundle",
          "capabilities": {
            "primaryPanel": true,
            "componentPanel": false,
            "configuration": true
          },
          "permissions": []
        }
        """.data(using: .utf8)!
        try manifestData.write(to: installedURL.appendingPathComponent("plugin.json"))

        let record = try XCTUnwrap(store.installedRecords().first)

        XCTAssertEqual(record.id, "com.example.legacy")
        XCTAssertEqual(record.manifest.version, "3.2.1")
        XCTAssertEqual(record.manifest.capabilities.settings, .form)
        XCTAssertEqual(
            record.state,
            .incompatible(
                AppL10n.pluginsFormat(
                    "plugin.error.store.installedSDKIncompatibleFormat",
                    defaultValue: "插件 SDK 版本不兼容，已安装版本为 %d，当前支持版本为 %d。请更新插件。",
                    3,
                    PluginPackageManifestLoader.supportedPluginKitVersion
                )
            )
        )
    }

    func testUninstallDeletesPackageAndCanRemoveStorage() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let storage = UserDefaultsPluginStorage(pluginID: "com.example.demo", userDefaults: defaults)
        storage.set("value", forKey: "setting")

        try store.uninstall(pluginID: "com.example.demo", removeData: true)

        XCTAssertTrue(store.installedRecords().isEmpty)
        XCTAssertNil(defaults.object(forKey: "plugin.com.example.demo.setting"))
    }

    func testManifestPolicyRemovesPrivateDataAndKeyWithoutLoadedPlugin() throws {
        var removedKeyPluginIDs: [String] = []
        let sourceURL = try makePackage(
            id: "com.example.private",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(privateDataKeyRemover: { removedKeyPluginIDs.append($0) })
        _ = try store.installPackage(from: sourceURL)
        let supportDirectory = store.dataDirectory.appendingPathComponent(
            "com.example.private",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: supportDirectory.appendingPathComponent("history.mth"))
        UserDefaultsPluginStorage(pluginID: "com.example.private", userDefaults: defaults)
            .set(true, forKey: "enabled")

        try store.uninstall(pluginID: "com.example.private", removeData: false)

        XCTAssertEqual(removedKeyPluginIDs, ["com.example.private"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportDirectory.path))
        XCTAssertNil(defaults.object(forKey: "plugin.com.example.private.enabled"))
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testPrivateDataCleanupAttemptsKeyDeletionAfterDirectoryFailure() throws {
        var removedKeyPluginIDs: [String] = []
        let sourceURL = try makePackage(
            id: "com.example.private",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(
            privateDataDirectoryRemover: { _ in throw CocoaError(.fileWriteNoPermission) },
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        _ = try store.installPackage(from: sourceURL)
        let supportDirectory = store.dataDirectory.appendingPathComponent(
            "com.example.private",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.uninstall(pluginID: "com.example.private", removeData: false)) {
            guard let storeError = $0 as? PluginPackageStoreError,
                  case .privateDataRemovalFailed = storeError else {
                return XCTFail("Expected privateDataRemovalFailed, got \($0)")
            }
        }

        XCTAssertEqual(removedKeyPluginIDs, ["com.example.private"])
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testPackageStagingFailureLeavesPrivateDataAndKeyUntouched() throws {
        var removedKeyPluginIDs: [String] = []
        let sourceURL = try makePackage(
            id: "com.example.private",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(
            packageFileMover: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        _ = try store.installPackage(from: sourceURL)
        let supportDirectory = store.dataDirectory.appendingPathComponent(
            "com.example.private",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let historyURL = supportDirectory.appendingPathComponent("history.sqlite3")
        try Data("private".utf8).write(to: historyURL)

        XCTAssertThrowsError(try store.uninstall(pluginID: "com.example.private", removeData: false)) {
            guard case .removeFailed = $0 as? PluginPackageStoreError else {
                return XCTFail("Expected removeFailed, got \($0)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertTrue(removedKeyPluginIDs.isEmpty)
        XCTAssertEqual(store.installedRecords().map(\.id), ["com.example.private"])
    }

    func testPrivateUninstallJournalRecoversCrashBoundariesIdempotently() throws {
        let pluginIDs = [
            "com.example.private-before-stage",
            "com.example.private-after-stage",
            "com.example.private-after-directories",
        ]
        let store = makeStore(privateDataKeyRemover: { _ in })
        for pluginID in pluginIDs {
            let sourceURL = try makePackage(
                id: pluginID,
                uninstallDataPolicy: .removePrivateData
            )
            _ = try store.installPackage(from: sourceURL)
            let supportDirectory = store.dataDirectory.appendingPathComponent(
                pluginID,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            try Data("private".utf8).write(
                to: supportDirectory.appendingPathComponent("history.sqlite3")
            )
        }

        var intents: [String: String] = [:]
        for pluginID in pluginIDs {
            let stagedName = "uninstall-\(pluginID)-crash.mactoolsplugin"
            intents[pluginID] = stagedName
            guard pluginID != pluginIDs[0] else { continue }
            let installedURL = store.installedDirectory
                .appendingPathComponent(pluginID, isDirectory: true)
                .appendingPathExtension("mactoolsplugin")
            try FileManager.default.moveItem(
                at: installedURL,
                to: store.stagingDirectory.appendingPathComponent(stagedName)
            )
        }
        try FileManager.default.removeItem(
            at: store.dataDirectory.appendingPathComponent(pluginIDs[2], isDirectory: true)
        )
        defaults.set(intents, forKey: "plugins.dynamic.privateUninstallIntents")
        XCTAssertTrue(defaults.synchronize())

        var removedKeyPluginIDs: [String] = []
        let recoveredStore = makeStore(
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )

        XCTAssertTrue(recoveredStore.installedRecords().isEmpty)
        XCTAssertEqual(Set(removedKeyPluginIDs), Set(pluginIDs))
        for pluginID in pluginIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredStore.dataDirectory
                .appendingPathComponent(pluginID, isDirectory: true).path))
        }
        let stagedResidue = try FileManager.default.contentsOfDirectory(
            at: recoveredStore.stagingDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("com.example.private-") }
        XCTAssertTrue(stagedResidue.isEmpty)
        XCTAssertEqual(
            defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count,
            0
        )

        let secondRecovery = makeStore(
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        XCTAssertTrue(secondRecovery.installedRecords().isEmpty)
        XCTAssertEqual(removedKeyPluginIDs.count, pluginIDs.count)
    }

    func testPrivateUninstallJournalRejectsUnsafePathsWithoutDeletingThem() throws {
        let protectedURL = temporaryRoot.appendingPathComponent("protected.mactoolsplugin")
        try FileManager.default.createDirectory(
            at: protectedURL,
            withIntermediateDirectories: true
        )
        defaults.set(
            ["../protected": "../protected.mactoolsplugin"],
            forKey: "plugins.dynamic.privateUninstallIntents"
        )
        XCTAssertTrue(defaults.synchronize())

        _ = makeStore(privateDataKeyRemover: { _ in
            XCTFail("Invalid journal must not remove a private key")
        })

        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertEqual(
            defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count,
            0
        )
    }

    func testCompletedPrivateUninstallJournalDoesNotRemoveFreshReinstall() throws {
        let pluginID = "com.example.private-reinstall"
        let sourceURL = try makePackage(
            id: pluginID,
            uninstallDataPolicy: .removePrivateData
        )
        var synchronizationCount = 0
        var removedKeyPluginIDs: [String] = []
        let store = makeStore(
            synchronizeUserDefaults: { defaults in
                synchronizationCount += 1
                if synchronizationCount == 3 {
                    return false
                }
                return defaults.synchronize()
            },
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        _ = try store.installPackage(from: sourceURL)

        try store.uninstall(pluginID: pluginID, removeData: false)
        XCTAssertEqual(removedKeyPluginIDs, [pluginID])

        let reinstalled = try store.installPackage(from: sourceURL)

        XCTAssertEqual(reinstalled.id, pluginID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reinstalled.packageURL.path))
        XCTAssertEqual(store.installedRecords().map(\.id), [pluginID])
        XCTAssertEqual(removedKeyPluginIDs, [pluginID])
        XCTAssertEqual(
            defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count,
            0
        )
    }

    func testReinstallWaitsForFailedPrivateDirectoryCleanupToRecover() throws {
        try assertReinstallWaitsForPrivateCleanup(failsDirectoryRemoval: true)
    }

    func testReinstallWaitsForFailedPrivateKeyCleanupToRecover() throws {
        try assertReinstallWaitsForPrivateCleanup(failsDirectoryRemoval: false)
    }

    private func assertReinstallWaitsForPrivateCleanup(failsDirectoryRemoval: Bool) throws {
        let pluginID = "com.example.private-pending-reinstall"
        let sourceURL = try makePackage(id: pluginID, uninstallDataPolicy: .removePrivateData)
        var cleanupFails = true
        var removedKeyPluginIDs: [String] = []
        let store = makeStore(
            privateDataDirectoryRemover: { url in
                if cleanupFails && failsDirectoryRemoval { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            },
            privateDataKeyRemover: { id in
                if cleanupFails && !failsDirectoryRemoval { throw CocoaError(.fileWriteNoPermission) }
                removedKeyPluginIDs.append(id)
            }
        )
        let original = try store.installPackage(from: sourceURL)
        let context = store.runtimeContext(for: original)
        let privateURL = try XCTUnwrap(context.supportDirectory).appendingPathComponent("private-data")
        try Data("original private data".utf8).write(to: privateURL)

        XCTAssertThrowsError(try store.uninstall(pluginID: pluginID, removeData: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.packageURL.path))
        XCTAssertThrowsError(try store.installPackage(from: sourceURL)) { error in
            guard case .installFailed = error as? PluginPackageStoreError else {
                return XCTFail("Expected installFailed while private cleanup is pending, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.packageURL.path),
            "A rejected reinstall must not leave a new package under the old cleanup intent")
        let pending = defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?[pluginID]
            as? [String: String]
        XCTAssertEqual(pending?["phase"], "staging")

        cleanupFails = false
        let reinstalled = try store.installPackage(from: sourceURL)
        XCTAssertEqual(reinstalled.id, pluginID)
        XCTAssertEqual(defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count, 0)
        let freshContext = store.runtimeContext(for: reinstalled)
        let freshURL = try XCTUnwrap(freshContext.supportDirectory).appendingPathComponent("fresh-data")
        try Data("fresh private data".utf8).write(to: freshURL)
        let keyRemovalsAfterRecovery = removedKeyPluginIDs.count
        XCTAssertEqual(store.installedRecords().map(\.id), [pluginID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
        XCTAssertEqual(removedKeyPluginIDs.count, keyRemovalsAfterRecovery,
            "Old uninstall recovery must never remove the new installation's key")
    }

    func testCleanupCompletePackageResidueDoesNotBlockOrDamageReinstall() throws {
        let pluginID = "com.example.private-residue-reinstall"
        let sourceURL = try makePackage(id: pluginID, uninstallDataPolicy: .removePrivateData)
        var residueRemovalFails = true
        var removedKeyPluginIDs: [String] = []
        let store = makeStore(
            packageFileRemover: { url in
                if residueRemovalFails { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            },
            privateDataKeyRemover: { removedKeyPluginIDs.append($0) }
        )
        _ = try store.installPackage(from: sourceURL)
        try store.uninstall(pluginID: pluginID, removeData: false)
        let pending = defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?[pluginID]
            as? [String: String]
        XCTAssertEqual(pending?["phase"], "cleanupComplete")

        let reinstalled = try store.installPackage(from: sourceURL)
        let context = store.runtimeContext(for: reinstalled)
        let freshURL = try XCTUnwrap(context.supportDirectory).appendingPathComponent("fresh-data")
        try Data("fresh private data".utf8).write(to: freshURL)
        XCTAssertEqual(store.installedRecords().map(\.id), [pluginID])
        XCTAssertEqual(removedKeyPluginIDs, [pluginID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))

        residueRemovalFails = false
        XCTAssertEqual(store.installedRecords().map(\.id), [pluginID])
        XCTAssertEqual(defaults.dictionary(forKey: "plugins.dynamic.privateUninstallIntents")?.count, 0)
        XCTAssertEqual(removedKeyPluginIDs, [pluginID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
    }

    func testFailedUpdateRestoresExistingPackage() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let invalidUpdateURL = try makePackage(id: "com.example.demo", version: "2.0.0", bundleRelativePath: "Missing.bundle")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        do {
            _ = try store.updatePackage(from: invalidUpdateURL)
            XCTFail("Expected update failure")
        } catch {
            // Expected path.
        }

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.manifest.version, "1.0.0")
        XCTAssertEqual(record.state, .installed)
    }

    func testUpdateClearsNeitherPackageNorVisibilityMigrationMarker() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let updateURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        _ = try store.updatePackage(from: updateURL)

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.manifest.version, "2.0.0")
        XCTAssertEqual(record.state, .installed)
    }

    func testInstallDateSurvivesUpdatesAndResetsAfterReinstall() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let updateURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        var currentDate = Date(timeIntervalSince1970: 100)
        let store = makeStore(now: { currentDate })

        let installedRecord = try store.installPackage(from: sourceURL)
        XCTAssertEqual(installedRecord.installedAt, currentDate)

        currentDate = Date(timeIntervalSince1970: 200)
        let updatedRecord = try store.updatePackage(from: updateURL)
        XCTAssertEqual(updatedRecord.installedAt, Date(timeIntervalSince1970: 100))

        try store.uninstall(pluginID: "com.example.demo", removeData: false)
        currentDate = Date(timeIntervalSince1970: 300)
        let reinstalledRecord = try store.installPackage(from: sourceURL)
        XCTAssertEqual(reinstalledRecord.installedAt, currentDate)
    }

    func testUpdateDoesNotInstallPackageThatIsNoLongerInstalled() throws {
        let updateURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()

        XCTAssertThrowsError(try store.updatePackage(from: updateURL)) { error in
            guard let storeError = error as? PluginPackageStoreError,
                  case let .packageNotFound(pluginID) = storeError else {
                return XCTFail("Expected packageNotFound, got \(error)")
            }

            XCTAssertEqual(pluginID, "com.example.demo")
        }
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testDefaultRootDirectoryUsesCurrentApplicationSupportScope() {
        let rootDirectory = PluginPackageStore.defaultRootDirectory(fileManager: .default)

        XCTAssertEqual(rootDirectory.lastPathComponent, "Plugins")
        XCTAssertEqual(
            rootDirectory.deletingLastPathComponent().lastPathComponent,
            AppStorageScope.applicationSupportDirectoryName
        )
    }

    func testApplicationSupportScopeUsesConfiguredNightlyDirectory() {
        XCTAssertEqual(
            AppStorageScope.applicationSupportDirectoryName(
                infoDictionary: ["MTApplicationSupportDirectoryName": "MacTools Nightly"]
            ),
            "MacTools Nightly"
        )
    }

    func testApplicationSupportScopeRejectsUnexpandedBuildSetting() {
        let name = AppStorageScope.applicationSupportDirectoryName(
            infoDictionary: ["MTApplicationSupportDirectoryName": "$(APPLICATION_SUPPORT_DIRECTORY_NAME)"]
        )

        #if DEBUG
        XCTAssertEqual(name, "MacTools Dev")
        #else
        XCTAssertEqual(name, "MacTools")
        #endif
    }

    private func makeStore(
        synchronizeUserDefaults: @escaping (UserDefaults) -> Bool = { $0.synchronize() },
        packageFileMover: ((URL, URL) throws -> Void)? = nil,
        packageFileRemover: ((URL) throws -> Void)? = nil,
        privateDataDirectoryRemover: ((URL) throws -> Void)? = nil,
        privateDataKeyRemover: ((String) throws -> Void)? = nil,
        now: @escaping () -> Date = { Date() }
    ) -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            synchronizeUserDefaults: synchronizeUserDefaults,
            packageFileMover: packageFileMover,
            packageFileRemover: packageFileRemover,
            privateDataDirectoryRemover: privateDataDirectoryRemover,
            privateDataKeyRemover: privateDataKeyRemover,
            now: now,
            hostVersion: "1.0.0"
        )
    }

    private func markLegacyDisabled(_ pluginID: String) {
        defaults.set([pluginID], forKey: "plugins.dynamic.disabledPluginIDs")
    }

    private func makePackage(
        id: String,
        version: String = "1.0.0",
        bundleRelativePath: String = "Demo.bundle",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        uninstallDataPolicy: PluginPackageManifest.UninstallDataPolicy? = nil
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        if bundleRelativePath == "Demo.bundle" {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        }

        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Demo",
            version: version,
            minHostVersion: "0.1.0",
            pluginKitVersion: pluginKitVersion,
            bundleRelativePath: bundleRelativePath,
            uninstallDataPolicy: uninstallDataPolicy
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }
}
