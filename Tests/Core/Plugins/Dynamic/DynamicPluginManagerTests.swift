import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class DynamicPluginManagerTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "DynamicPluginManagerTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicPluginManagerTests-\(UUID().uuidString)", isDirectory: true)
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

    func testReloadKeepsExistingLoadedPluginInstances() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])
        XCTAssertTrue(plugin.deactivationReasons.isEmpty)
    }

    func testFutureHostCatalogEntryIsVisibleButCannotBeInstalled() throws {
        let store = makeStore()
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        let entry = PluginCatalogEntry(
            id: "com.example.future",
            displayName: "Future",
            summary: "Future host only",
            version: "1.0.0",
            minimumHostVersion: "2.0.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/Future.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
        manager.rebuildManagementItems(catalogSnapshot: PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.catalog",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "1.0.0",
                plugins: [entry]
            ),
            sourceURL: URL(fileURLWithPath: "/tmp/catalog.json"),
            sourceKind: .production,
            loadedAt: Date(timeIntervalSince1970: 0)
        ))

        let item = try XCTUnwrap(manager.pluginManagementItems.first)
        XCTAssertFalse(item.canInstall)
        guard case let .incompatible(reason) = item.state else {
            return XCTFail("Expected incompatible marketplace entry")
        }
        XCTAssertTrue(reason.contains("2.0.0"))
    }

    func testUpdatingLoadedPluginInstallsFilesButDoesNotReloadNativeCodeUntilRestart() throws {
        let firstPackageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let updatePackageURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: firstPackageURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        try manager.updatePluginPackage(from: updatePackageURL)

        XCTAssertEqual(plugin.deactivationReasons, [.updating])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertEqual(store.installedRecords().first?.manifest.version, "2.0.0")
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .restartRequired)
        XCTAssertEqual(
            manager.pluginManagementItems.first?.detailText,
            AppL10n.plugins(
                "plugin.detail.restartRequiredAfterUpdate",
                defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。"
            )
        )
    }

    func testUpdateThenUninstallUsesManifestOwnedPrivateDataCleanup() throws {
        var removedKeyPluginIDs: [String] = []
        let firstPackageURL = try makePackage(
            id: "com.example.private",
            version: "1.0.0",
            uninstallDataPolicy: .removePrivateData
        )
        let updatePackageURL = try makePackage(
            id: "com.example.private",
            version: "2.0.0",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(privateDataKeyRemover: { removedKeyPluginIDs.append($0) })
        _ = try store.installPackage(from: firstPackageURL)
        let plugin = MockDynamicPlugin(id: "com.example.private")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        _ = manager.loadInstalledPlugins()

        try manager.updatePluginPackage(from: updatePackageURL)
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        try manager.uninstallPlugin(pluginID: "com.example.private")

        XCTAssertEqual(removedKeyPluginIDs, ["com.example.private"])
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testUnloadablePluginUninstallUsesManifestOwnedPrivateDataCleanup() throws {
        var removedKeyPluginIDs: [String] = []
        let sourceURL = try makePackage(
            id: "com.example.private",
            uninstallDataPolicy: .removePrivateData
        )
        let store = makeStore(privateDataKeyRemover: { removedKeyPluginIDs.append($0) })
        _ = try store.installPackage(from: sourceURL)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [], errorMessage: "load failed")
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)

        try manager.uninstallPlugin(pluginID: "com.example.private")

        XCTAssertEqual(removedKeyPluginIDs, ["com.example.private"])
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testDirectSourceRetirementUpdateRequiresExtractionCoordinator() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let retiredMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.updatePluginPackage(from: retiredMouseURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["mouse-enhancer": "1.0.6"])
    }

    func testDirectDestinationInstallRequiresExtractionCoordinator() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.installPluginPackage(from: trackpadURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["mouse-enhancer": "1.0.6"])
    }

    func testDirectSourceDowngradeCannotRecreateOldOwnerBesideDestination() throws {
        let currentMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: currentMouseURL)
        _ = try store.installPackage(from: trackpadURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.updatePluginPackage(from: oldMouseURL))
        XCTAssertEqual(manager.installedPackageVersionsByID()["mouse-enhancer"], "1.0.7")
    }

    func testDirectDestinationDowngradeCannotRemoveExtractedCapability() throws {
        let currentMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let currentTrackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let oldTrackpadURL = try makePackage(id: "trackpad-gestures", version: "0.9.0")
        let store = makeStore()
        _ = try store.installPackage(from: currentMouseURL)
        _ = try store.installPackage(from: currentTrackpadURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.updatePluginPackage(from: oldTrackpadURL))
        XCTAssertEqual(manager.installedPackageVersionsByID()["trackpad-gestures"], "1.0.0")
    }

    func testCompletedExtractionKeepsMouseEnhancerLoadableAfterHostDowngrade() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        defaults.set(true, forKey: policy.completionKey)
        let currentStore = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            hostVersion: "1.1.6"
        )
        _ = try currentStore.installPackage(from: makePackage(
            id: policy.sourcePluginID,
            version: "1.0.7",
            minHostVersion: "1.1.3"
        ))
        _ = try currentStore.installPackage(from: makePackage(
            id: policy.destinationPluginID,
            version: "1.0.0",
            minHostVersion: "1.1.6"
        ))

        let downgradedStore = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            hostVersion: "1.1.5"
        )
        let mousePlugin = MockDynamicPlugin(id: policy.sourcePluginID)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: record.id == policy.sourcePluginID ? [mousePlugin] : [],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(
            packageStore: downgradedStore,
            pluginLoader: loader
        )

        let downgradedRecords = Dictionary(
            uniqueKeysWithValues: downgradedStore.installedRecords().map { ($0.id, $0) }
        )
        XCTAssertEqual(downgradedRecords[policy.sourcePluginID]?.state, .installed)
        XCTAssertEqual(
            downgradedRecords[policy.destinationPluginID]?.state,
            .incompatible(AppL10n.pluginsFormat(
                "plugin.error.store.installedHostIncompatibleFormat",
                defaultValue: "插件需要 MacTools %@ 或更高版本，当前版本为 %@。",
                "1.1.6",
                "1.1.5"
            ))
        )
        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), [policy.sourcePluginID])
    }

    func testDirectOldDestinationReinstallCannotRemoveExtractedCapability() throws {
        let currentMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let oldTrackpadURL = try makePackage(id: "trackpad-gestures", version: "0.9.0")
        let store = makeStore()
        _ = try store.installPackage(from: currentMouseURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.installPluginPackage(from: oldTrackpadURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["mouse-enhancer": "1.0.7"])
    }

    func testCompletedExtractionProtectsDestinationAfterSourceUninstall() throws {
        defaults.set(
            true,
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1"
        )
        let currentMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.7")
        let currentTrackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let oldTrackpadURL = try makePackage(id: "trackpad-gestures", version: "0.9.0")
        let store = makeStore()
        _ = try store.installPackage(from: currentMouseURL)
        _ = try store.installPackage(from: currentTrackpadURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        try manager.uninstallPlugin(pluginID: "mouse-enhancer")
        XCTAssertThrowsError(try manager.updatePluginPackage(from: oldTrackpadURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["trackpad-gestures": "1.0.0"])

        try manager.uninstallPlugin(pluginID: "trackpad-gestures")
        XCTAssertThrowsError(try manager.installPluginPackage(from: oldTrackpadURL))
        XCTAssertTrue(manager.installedPackageVersionsByID().isEmpty)
    }

    func testSourceUninstallDoesNotDeletePackageWhenIntentCannotPersist() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        defaults.set(true, forKey: policy.transactionJournalKey)
        let sourceURL = try makePackage(id: policy.sourcePluginID, version: "1.0.6")
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            synchronizeUserDefaults: { _ in false },
            hostVersion: "1.0.0"
        )
        _ = try store.installPackage(from: sourceURL)

        XCTAssertThrowsError(try store.uninstall(pluginID: policy.sourcePluginID, removeData: false)) {
            guard case PluginPackageStoreError.migrationStatePersistenceFailed = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        XCTAssertEqual(store.installedRecords().map(\.id), [policy.sourcePluginID])
        XCTAssertNil(defaults.object(forKey: policy.sourceUninstallIntentKey))
        XCTAssertTrue(defaults.bool(forKey: policy.transactionJournalKey))
    }

    func testSourceUninstallIntentFinishesDeletionAfterRestartBeforePackageRemoval() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        let sourceURL = try makePackage(id: policy.sourcePluginID, version: "1.0.6")
        let initialStore = makeStore()
        _ = try initialStore.installPackage(from: sourceURL)
        let sourcePreferenceKey = "plugin.\(policy.sourcePluginID).test-value"
        defaults.set("preserved-until-uninstall", forKey: sourcePreferenceKey)
        defaults.set(true, forKey: policy.transactionJournalKey)
        defaults.set(true, forKey: policy.sourceUninstallIntentKey)
        defaults.set(true, forKey: policy.sourceUninstallRemoveDataKey)
        XCTAssertTrue(defaults.synchronize())

        let relaunchedStore = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )

        XCTAssertTrue(relaunchedStore.installedRecords().isEmpty)
        XCTAssertNil(defaults.object(forKey: sourcePreferenceKey))
        assertSourceUninstallRecoveryCompleted(policy: policy)
    }

    func testSourceUninstallIntentFinalizesAfterRestartWhenPackageWasAlreadyRemoved() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        let sourceURL = try makePackage(id: policy.sourcePluginID, version: "1.0.6")
        let initialStore = makeStore()
        let record = try initialStore.installPackage(from: sourceURL)
        defaults.set(true, forKey: policy.transactionJournalKey)
        defaults.set(true, forKey: policy.sourceUninstallIntentKey)
        defaults.set(false, forKey: policy.sourceUninstallRemoveDataKey)
        XCTAssertTrue(defaults.synchronize())
        try FileManager.default.removeItem(at: record.packageURL)

        let relaunchedStore = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )

        XCTAssertTrue(relaunchedStore.installedRecords().isEmpty)
        assertSourceUninstallRecoveryCompleted(policy: policy)
    }

    func testSourceUninstallRecoveryUsesDurableIntentWhenFinalWritesAreLost() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        let durableKeys = [
            policy.completionKey,
            policy.transactionJournalKey,
            policy.sourceUninstallIntentKey,
            policy.sourceUninstallRemoveDataKey,
        ]
        var synchronizationCount = 0
        var durableSnapshot: [String: Any] = [:]
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            synchronizeUserDefaults: { currentDefaults in
                synchronizationCount += 1
                guard synchronizationCount != 2 else { return false }
                durableSnapshot = Dictionary(
                    uniqueKeysWithValues: durableKeys.compactMap { key in
                        currentDefaults.object(forKey: key).map { (key, $0) }
                    }
                )
                return true
            },
            hostVersion: "1.0.0"
        )
        let installedSource = try store.installPackage(
            from: makePackage(id: policy.sourcePluginID, version: "1.0.6")
        )
        defaults.set(true, forKey: policy.transactionJournalKey)

        try store.uninstall(pluginID: policy.sourcePluginID, removeData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedSource.packageURL.path))
        XCTAssertEqual(synchronizationCount, 2)
        XCTAssertEqual(durableSnapshot[policy.sourceUninstallIntentKey] as? Bool, true)
        XCTAssertEqual(durableSnapshot[policy.transactionJournalKey] as? Bool, true)
        XCTAssertNil(durableSnapshot[policy.completionKey])

        let crashSuiteName = "\(suiteName)-Crash-\(UUID().uuidString)"
        let crashDefaults = UserDefaults(suiteName: crashSuiteName)!
        defer { crashDefaults.removePersistentDomain(forName: crashSuiteName) }
        for (key, value) in durableSnapshot {
            crashDefaults.set(value, forKey: key)
        }
        XCTAssertTrue(crashDefaults.synchronize())

        let relaunchedStore = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: UserDefaults(suiteName: crashSuiteName)!,
            hostVersion: "1.0.0"
        )

        XCTAssertTrue(relaunchedStore.installedRecords().isEmpty)
        assertSourceUninstallRecoveryCompleted(policy: policy, defaults: crashDefaults)
    }

    func testSourceUninstallRecoveryCleansTombstoneAfterCompletionWasPersisted() throws {
        let policy = PluginExtractionMigrationPolicy.mouseEnhancerMiddleClick
        defaults.set(true, forKey: policy.completionKey)
        defaults.set(true, forKey: policy.sourceUninstallIntentKey)
        defaults.set(false, forKey: policy.sourceUninstallRemoveDataKey)
        XCTAssertTrue(defaults.synchronize())

        let relaunchedStore = PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )

        XCTAssertTrue(relaunchedStore.installedRecords().isEmpty)
        assertSourceUninstallRecoveryCompleted(policy: policy)
    }

    func testNeverMigratedSourceFreeDestinationCanUseLegacyVersion() throws {
        let currentTrackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let oldTrackpadURL = try makePackage(id: "trackpad-gestures", version: "0.9.0")
        let store = makeStore()
        _ = try store.installPackage(from: currentTrackpadURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        try manager.updatePluginPackage(from: oldTrackpadURL)

        XCTAssertEqual(manager.installedPackageVersionsByID(), ["trackpad-gestures": "0.9.0"])
    }

    func testDirectOldSourceReinstallCannotCreateSecondOwner() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: trackpadURL)
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )

        XCTAssertThrowsError(try manager.installPluginPackage(from: oldMouseURL))
        XCTAssertEqual(manager.installedPackageVersionsByID(), ["trackpad-gestures": "1.0.0"])
    }

    func testLostJournalLoadsValidatedDestinationWithoutLegacySource() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        _ = try store.installPackage(from: trackpadURL)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(
            manager.loadInstalledPlugins().map(\.metadata.id),
            ["trackpad-gestures"]
        )
        XCTAssertEqual(loader.receivedRecordIDBatches, [["trackpad-gestures"]])
        XCTAssertTrue(manager.featureExtractionMigrationIsInProgress())
        XCTAssertNil(defaults.object(
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        ))
    }

    func testLostJournalFallsBackToLegacySourceAfterDestinationReadinessFailure() throws {
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        _ = try store.installPackage(from: trackpadURL)
        let destinationPlugin = MockDynamicPlugin(
            id: "trackpad-gestures",
            readinessError: MockFeatureExtractionReadinessError.listenerUnavailable
        )
        let sourcePlugin = MockDynamicPlugin(id: "mouse-enhancer")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [
                        record.id == "trackpad-gestures" ? destinationPlugin : sourcePlugin,
                    ],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(
            manager.loadInstalledPlugins().map(\.metadata.id),
            ["mouse-enhancer"]
        )
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["trackpad-gestures"],
            ["mouse-enhancer"],
        ])
        XCTAssertEqual(destinationPlugin.deactivationReasons, [.disabled])
    }

    func testPersistedJournalLoadsLegacySourceWhenDestinationIsAbsent() throws {
        defaults.set(
            true,
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        )
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["mouse-enhancer"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [["mouse-enhancer"]])
    }

    func testPersistedJournalKeepsLegacyFallbackAfterDestinationReadinessFailure() throws {
        defaults.set(
            true,
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        )
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let trackpadURL = try makePackage(id: "trackpad-gestures", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        _ = try store.installPackage(from: trackpadURL)
        let destinationPlugin = MockDynamicPlugin(
            id: "trackpad-gestures",
            readinessError: MockFeatureExtractionReadinessError.listenerUnavailable
        )
        let sourcePlugin = MockDynamicPlugin(id: "mouse-enhancer")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [
                        record.id == "trackpad-gestures" ? destinationPlugin : sourcePlugin,
                    ],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["mouse-enhancer"])
        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["mouse-enhancer"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["trackpad-gestures"],
            ["mouse-enhancer"],
        ])
        XCTAssertEqual(destinationPlugin.deactivationReasons, [.disabled])
    }

    func testPersistedJournalRejectsBelowMinimumDestinationBeforeSourceFallback() throws {
        defaults.set(
            true,
            forKey: "plugins.dynamic.extraction.mouse-enhancer-middle-click.v1.in-progress"
        )
        let oldMouseURL = try makePackage(id: "mouse-enhancer", version: "1.0.6")
        let oldTrackpadURL = try makePackage(id: "trackpad-gestures", version: "0.9.0")
        let store = makeStore()
        _ = try store.installPackage(from: oldMouseURL)
        _ = try store.installPackage(from: oldTrackpadURL)
        let destinationPlugin = MockDynamicPlugin(id: "trackpad-gestures")
        let sourcePlugin = MockDynamicPlugin(id: "mouse-enhancer")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [
                        record.id == "trackpad-gestures" ? destinationPlugin : sourcePlugin,
                    ],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["mouse-enhancer"])
        XCTAssertEqual(destinationPlugin.deactivationReasons, [.disabled])
    }

    func testBatchUpdatingLoadedPluginsReloadsOnlyOnce() async throws {
        let firstAlphaURL = try makePackage(id: "com.example.alpha", version: "1.0.0", displayName: "Alpha")
        let firstBetaURL = try makePackage(id: "com.example.beta", version: "1.0.0", displayName: "Beta")
        let updateAlphaURL = try makePackage(id: "com.example.alpha", version: "2.0.0", displayName: "Alpha")
        let updateBetaURL = try makePackage(id: "com.example.beta", version: "2.0.0", displayName: "Beta")
        let store = makeStore()
        _ = try store.installPackage(from: firstAlphaURL)
        _ = try store.installPackage(from: firstBetaURL)
        let alphaPlugin = MockDynamicPlugin(id: "com.example.alpha")
        let betaPlugin = MockDynamicPlugin(id: "com.example.beta")
        let pluginsByID = [
            "com.example.alpha": alphaPlugin,
            "com.example.beta": betaPlugin,
        ]
        let loader = StubDynamicPluginLoader { records in
            records.compactMap { record in
                guard let plugin = pluginsByID[record.id] else {
                    return nil
                }

                return DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        var pluginChangeBatches: [[String]] = []
        manager.onPluginsChanged = { plugins in
            pluginChangeBatches.append(plugins.map(\.metadata.id))
        }

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.alpha", "com.example.beta"])

        let failures = await manager.updatePluginPackages([
            (sourceURL: updateAlphaURL, catalogEntry: makeCatalogEntry(id: "com.example.alpha", version: "2.0.0")),
            (sourceURL: updateBetaURL, catalogEntry: makeCatalogEntry(id: "com.example.beta", version: "2.0.0")),
        ])

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["com.example.alpha", "com.example.beta"],
        ])
        XCTAssertEqual(pluginChangeBatches, [[]])
        XCTAssertEqual(alphaPlugin.deactivationReasons, [.updating])
        XCTAssertEqual(betaPlugin.deactivationReasons, [.updating])
        XCTAssertEqual(
            store.installedRecords().map { "\($0.id):\($0.manifest.version)" },
            [
                "com.example.alpha:2.0.0",
                "com.example.beta:2.0.0",
            ]
        )
        XCTAssertTrue(manager.pluginManagementItems.allSatisfy { item in
            if case .restartRequired = item.state {
                return true
            }

            return false
        })
    }

    func testUninstallingLoadedPluginDeletesPackageAndRemovesManagementItem() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        try manager.uninstallPlugin(pluginID: "com.example.demo")

        XCTAssertEqual(plugin.deactivationReasons, [.uninstalling])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertTrue(manager.pluginManagementItems.isEmpty)
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testMigrationRuntimeValidationTearsDownValidatedInstance() throws {
        let sourceURL = try makePackage(id: "com.example.replacement")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.replacement")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        manager.prepareInstalledPluginsWithoutLoading()

        try manager.validatePluginInstallationBeforeMigration(
            pluginID: "com.example.replacement"
        )

        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.replacement"]])
        XCTAssertEqual(plugin.deactivationReasons, [.updating])
    }

    func testCatalogEntryAddsAvailableManagementItem() throws {
        let store = makeStore()
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: "com.example.demo", version: "1.0.0")])

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(manager.pluginManagementItems.map(\.id), ["com.example.demo"])
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .available)
        XCTAssertEqual(manager.pluginManagementItems.first?.canInstall, true)
    }

    func testCatalogEntryShowsUpdateWhenNewerThanInstalledVersion() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        _ = manager.loadInstalledPlugins()
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: "com.example.demo", version: "2.0.0")])

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(
            manager.pluginManagementItems.first?.state,
            .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0")
        )
        XCTAssertEqual(manager.pluginManagementItems.first?.canUpdate, true)
    }

    func testLocalDevelopmentCatalogEntryUsesLocalDevelopmentState() throws {
        let store = makeStore()
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let snapshot = makeCatalogSnapshot(
            entries: [makeCatalogEntry(id: "com.example.demo", version: "1.0.0")],
            sourceKind: .localDevelopment
        )

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(manager.pluginManagementItems.first?.state, .localDevelopment)
        XCTAssertEqual(manager.pluginManagementItems.first?.canInstall, true)
    }

    private func makeStore(
        privateDataKeyRemover: ((String) throws -> Void)? = nil
    ) -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            privateDataKeyRemover: privateDataKeyRemover,
            hostVersion: "1.0.0"
        )
    }

    private func assertSourceUninstallRecoveryCompleted(
        policy: PluginExtractionMigrationPolicy,
        defaults: UserDefaults? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let defaults = defaults ?? self.defaults!
        XCTAssertTrue(defaults.bool(forKey: policy.completionKey), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: policy.transactionJournalKey), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: policy.sourceUninstallIntentKey), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: policy.sourceUninstallRemoveDataKey), file: file, line: line)
    }

    private func makePackage(
        id: String,
        version: String = "1.0.0",
        displayName: String = "Demo",
        bundleRelativePath: String = "Demo.bundle",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        minHostVersion: String = "0.1.0",
        releaseChannel: String? = nil,
        uninstallDataPolicy: PluginPackageManifest.UninstallDataPolicy? = nil
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: displayName,
            version: version,
            minHostVersion: minHostVersion,
            pluginKitVersion: pluginKitVersion,
            bundleRelativePath: bundleRelativePath,
            releaseChannel: releaseChannel,
            uninstallDataPolicy: uninstallDataPolicy
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }

    private func makeCatalogEntry(
        id: String,
        version: String,
        releaseChannel: String? = nil
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/Demo.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            ),
            releaseChannel: releaseChannel
        )
    }

    private func makeCatalogSnapshot(
        entries: [PluginCatalogEntry],
        sourceKind: PluginCatalogSnapshot.SourceKind = .production
    ) -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.catalog",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "0.1.0",
                plugins: entries
            ),
            sourceURL: URL(string: "https://example.com/catalog.json")!,
            sourceKind: sourceKind,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private final class StubDynamicPluginLoader: DynamicPluginLoading {
    private let handler: ([PluginPackageRecord]) -> [DynamicPluginLoadResult]
    private(set) var receivedRecordIDBatches: [[String]] = []

    init(handler: @escaping ([PluginPackageRecord]) -> [DynamicPluginLoadResult]) {
        self.handler = handler
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDBatches.append(records.map(\.id))
        return handler(records)
    }
}

@MainActor
private final class MockDynamicPlugin: MacToolsPlugin, PluginFeatureExtractionReadinessProviding {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var deactivationReasons: [PluginDeactivationReason] = []
    private(set) var activationContexts: [PluginRuntimeContext] = []
    private let readinessError: Error?

    init(id: String, readinessError: Error? = nil) {
        self.readinessError = readinessError
        self.metadata = PluginMetadata(
            id: id,
            title: "Demo",
            iconName: "shippingbox",
            iconTint: .blue,
            order: 1,
            defaultDescription: "Demo"
        )
    }

    func activate(context: PluginRuntimeContext) {
        activationContexts.append(context)
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivationReasons.append(reason)
    }

    func validateFeatureExtractionReadiness() throws {
        if let readinessError {
            throw readinessError
        }
    }
}

private enum MockFeatureExtractionReadinessError: Error {
    case listenerUnavailable
}
