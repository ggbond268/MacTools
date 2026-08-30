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
        now: @escaping () -> Date = { Date() }
    ) -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
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
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion
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
            bundleRelativePath: bundleRelativePath
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }
}
