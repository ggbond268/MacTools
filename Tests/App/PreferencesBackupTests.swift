import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PreferencesBackupTests: XCTestCase {
    private let suiteName = "PreferencesBackupTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testExportContainsOnlyPortableHostAndKnownPluginPreferences() throws {
        let defaults = makeDefaults()
        defaults.set(AppAppearancePreference.dark.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        defaults.set(AppLanguagePreference.en.rawValue, forKey: AppLanguagePreference.userDefaultsKey)
        defaults.set(MenuBarClickBehaviorPreference.swapped.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
        defaults.set("api-key-value", forKey: "translator.apiKey")

        let firstPlugin = BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle")
        let secondPlugin = BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
        let host = makeHost(plugins: [firstPlugin, secondPlugin], defaults: defaults)
        host.setFeatureVisibility(false, for: firstPlugin.metadata.id)
        host.moveFeatureManagementItem(id: secondPlugin.metadata.id, by: -1)
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]),
            for: "first.shortcut.toggle"
        )

        let backup = host.makePreferencesBackup()
        let decodedBackup = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decodedBackup.formatVersion, PreferencesBackup.currentFormatVersion)
        XCTAssertEqual(decodedBackup.application, backup.application)
        XCTAssertEqual(decodedBackup.pluginDisplay, backup.pluginDisplay)
        XCTAssertEqual(decodedBackup.shortcutCustomizations, backup.shortcutCustomizations)
        XCTAssertEqual(backup.application.appearancePreference, AppAppearancePreference.dark.rawValue)
        XCTAssertEqual(backup.application.languagePreference, AppLanguagePreference.en.rawValue)
        XCTAssertEqual(backup.application.menuBarClickBehavior, MenuBarClickBehaviorPreference.swapped.rawValue)
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["second", "first"])
        XCTAssertEqual(backup.pluginDisplay.hiddenPluginIDs, ["first"])
        XCTAssertEqual(
            backup.shortcutCustomizations["first.shortcut.toggle"],
            .custom(ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]))
        )
        XCTAssertNil(backup.shortcutCustomizations["second.shortcut.open"])
        XCTAssertFalse(try XCTUnwrap(String(data: backup.encodedJSON(), encoding: .utf8)).contains("api-key-value"))
    }

    func testPreviewReportsUnavailablePluginAndShortcutSettings() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [BackupTestPlugin(id: "available", order: 1, shortcutID: "toggle")],
            defaults: defaults
        )
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["available", "unavailable"],
                hiddenPluginIDs: ["unavailable"]
            ),
            shortcutCustomizations: [
                "available.shortcut.toggle": .cleared,
                "unavailable.shortcut.toggle": .cleared
            ]
        )

        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.pluginCount, 1)
        XCTAssertEqual(preview.unavailablePluginIDs, ["unavailable"])
        XCTAssertEqual(preview.shortcutCount, 1)
        XCTAssertEqual(preview.unavailableShortcutIDs, ["unavailable.shortcut.toggle"])
    }

    func testPreviewOffersOnlyCatalogInstallableMissingPlugins() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["available", "installable", "incompatible"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:]
        )
        let preview = try PreferencesImportPreview.make(
            backup: backup,
            availablePluginIDs: ["available"],
            availableShortcutIDs: [],
            pluginManagementItems: [
                PluginManagementItem(
                    id: "installable",
                    title: "Installable",
                    summary: "Available from the verified catalog.",
                    version: "1.0.0",
                    state: .available,
                    packageURL: nil,
                    requiresRestartToFullyUnload: false,
                    releaseNotesURL: nil
                ),
                PluginManagementItem(
                    id: "incompatible",
                    title: "Incompatible",
                    summary: nil,
                    version: "1.0.0",
                    state: .incompatible("Requires a newer MacTools version."),
                    packageURL: nil,
                    requiresRestartToFullyUnload: false,
                    releaseNotesURL: nil
                )
            ],
            applicationPreferencesAreValid: { _ in true }
        )

        XCTAssertEqual(preview.installablePlugins.map(\.id), ["installable"])
        XCTAssertEqual(preview.unavailablePluginIDs, ["incompatible"])
    }

    func testImportRestoresDisplayPreferencesAndShortcutCustomizations() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: "first.shortcut.toggle"
        )
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["second", "unavailable", "first"],
                hiddenPluginIDs: ["first", "unavailable"]
            ),
            shortcutCustomizations: [
                "second.shortcut.open": .cleared,
                "unavailable.shortcut.toggle": .cleared
            ]
        )

        _ = try host.importPreferences(backup)

        XCTAssertEqual(host.featureManagementItems.map(\.id), ["second", "first"])
        XCTAssertFalse(host.featureManagementItems.first(where: { $0.id == "first" })?.isVisible ?? true)
        XCTAssertFalse(host.shortcutItems.first(where: { $0.id == "second.shortcut.open" })?.canClear ?? true)
        XCTAssertTrue(host.shortcutItems.first(where: { $0.id == "first.shortcut.toggle" })?.usesDefaultValue ?? false)
    }

    func testImportRestoresSwappedShortcutBindingsAtomically() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        let firstBinding = ShortcutBinding(keyCode: 12, modifiers: [.command])
        let secondBinding = ShortcutBinding(keyCode: 13, modifiers: [.command])
        host.setShortcutBinding(firstBinding, for: "first.shortcut.toggle")
        host.setShortcutBinding(secondBinding, for: "second.shortcut.open")
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: ["first", "second"], hiddenPluginIDs: []),
            shortcutCustomizations: [
                "first.shortcut.toggle": .custom(secondBinding),
                "second.shortcut.open": .custom(firstBinding)
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(
            host.makePreferencesBackup().shortcutCustomizations,
            backup.shortcutCustomizations
        )
    }

    func testInvalidShortcutImportLeavesAllShortcutCustomizationsUntouched() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        let firstBinding = ShortcutBinding(keyCode: 12, modifiers: [.command])
        let secondBinding = ShortcutBinding(keyCode: 13, modifiers: [.command])
        host.setShortcutBinding(firstBinding, for: "first.shortcut.toggle")
        host.setShortcutBinding(secondBinding, for: "second.shortcut.open")
        let existingCustomizations = host.makePreferencesBackup().shortcutCustomizations
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: ["first", "second"], hiddenPluginIDs: []),
            shortcutCustomizations: [
                "first.shortcut.toggle": .custom(firstBinding),
                "second.shortcut.open": .custom(firstBinding)
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertEqual(
            Set(result.shortcutErrors.keys),
            Set(["first.shortcut.toggle", "second.shortcut.open"])
        )
        XCTAssertEqual(host.makePreferencesBackup().shortcutCustomizations, existingCustomizations)
    }

    func testImportInstallsSelectedCatalogPluginThenAppliesItsDisplaySettings() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupInstallTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PreferencesBackupInstallTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let packageURL = try makeDynamicPluginPackage(
            at: temporaryRoot,
            id: "installable",
            version: "1.0.0"
        )
        let packageStore = PluginPackageStore(
            rootDirectory: temporaryRoot.appending(path: "Installed", directoryHint: .isDirectory),
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let dynamicManager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: BackupDynamicPluginLoader()
        )
        let entry = makeCatalogEntry(id: "installable", version: "1.0.0")
        let catalogManager = PluginCatalogManager(
            catalogProvider: BackupCatalogProvider(entries: [entry]),
            packageResolver: BackupPackageResolver(packagesByID: ["installable": packageURL]),
            dynamicPluginManager: dynamicManager,
            source: .production(URL(string: "https://example.com/catalog.json")!)
        )
        let host = PluginHost(
            plugins: [BackupTestPlugin(id: "built-in", order: 1, shortcutID: "toggle")],
            dynamicPluginManager: dynamicManager,
            pluginCatalogManager: catalogManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["installable", "built-in"],
                hiddenPluginIDs: ["installable"]
            ),
            shortcutCustomizations: [:]
        )

        await host.refreshPluginCatalog()
        let result = try await host.importPreferences(
            backup,
            installingMissingPluginIDs: ["installable"]
        )

        XCTAssertEqual(result.installedPluginIDs, ["installable"])
        XCTAssertTrue(result.pluginInstallationFailures.isEmpty)
        XCTAssertFalse(host.featureManagementItems.first(where: { $0.id == "installable" })?.isVisible ?? true)
    }

    func testDecodeRejectsUnsupportedFormatVersion() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        json["formatVersion"] = 2

        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))) { error in
            guard case PreferencesBackupError.unsupportedFormatVersion(2) = error else {
                return XCTFail("Expected unsupported format version error, got \(error)")
            }
        }
    }

    func testDecodeRejectsInvalidApplicationPreferences() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        var application = try XCTUnwrap(json["application"] as? [String: Any])
        application["languagePreference"] = "unsupported-language"
        json["application"] = application

        let decodedBackup = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        let store = PreferencesBackupStore(userDefaults: makeDefaults())

        XCTAssertThrowsError(try decodedBackup.validateApplicationPreferences(using: store.validates)) { error in
            guard case PreferencesBackupError.invalidApplicationPreferences = error else {
                return XCTFail("Expected invalid application preferences error, got \(error)")
            }
        }
    }

    func testDecodeRejectsUnsupportedShortcutModifierBits() throws {
        let binding = ShortcutBinding(
            keyCode: 12,
            modifiers: ShortcutModifiers(rawValue: 1 << 4)
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: ["plugin.shortcut.action": .custom(binding)]
        )

        XCTAssertFalse(binding.isValid)
        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(backup.encodedJSON())) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected invalid shortcut modifiers, got \(error)")
            }
        }
    }

    func testDecodeFileReadsValidBackupWithinSizeLimit() async throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try backup.encodedJSON().write(to: url)

        let decoded = try await PreferencesBackup.decodeJSON(contentsOf: url)

        XCTAssertEqual(decoded, backup)
    }

    func testDecodeFileRejectsContentAboveSizeLimit() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: PreferencesBackup.maximumFileSize + 1).write(to: url)

        do {
            _ = try await PreferencesBackup.decodeJSON(contentsOf: url)
            XCTFail("Expected oversized backup to be rejected")
        } catch {
            XCTAssertEqual(
                error as? PreferencesBackupError,
                .fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
            )
        }
    }

    func testApplicationPreferenceValidationAcceptsEveryCurrentAppEnumValue() throws {
        let store = PreferencesBackupStore(userDefaults: makeDefaults())

        for appearance in AppAppearancePreference.allCases {
            for language in AppLanguagePreference.allCases {
                for clickBehavior in [
                    MenuBarClickBehaviorPreference.standard,
                    .swapped
                ] {
                    let preferences = PreferencesBackup.ApplicationPreferences(
                        appearancePreference: appearance.rawValue,
                        languagePreference: language.rawValue,
                        menuBarClickBehavior: clickBehavior.rawValue
                    )

                    XCTAssertNoThrow(
                        try PreferencesBackup(
                            application: preferences,
                            pluginDisplay: PluginDisplayPreferencesBackup(
                                orderedPluginIDs: [],
                                hiddenPluginIDs: []
                            ),
                            shortcutCustomizations: [:]
                        ).validateApplicationPreferences(using: store.validates)
                    )
                }
            }
        }
    }

    func testExportFileNameIncludesLocalDateAndTime() {
        XCTAssertEqual(
            PreferencesBackupExportFileName.make(
                date: Date(timeIntervalSince1970: 0),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "MacTools Preferences 1970-01-01_00-00-00.json"
        )
    }

    private var validApplicationPreferences: PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.system.rawValue,
            languagePreference: AppLanguagePreference.system.rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
        )
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupTests-\(UUID().uuidString).json")
    }

    private func makeHost(
        plugins: [any MacToolsPlugin],
        defaults: UserDefaults
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }

    private func makeDynamicPluginPackage(at root: URL, id: String, version: String) throws -> URL {
        let packageURL = root
            .appending(path: "Source/\(id)-\(UUID().uuidString).mactoolsplugin", directoryHint: .isDirectory)
        let bundleRelativePath = "Demo.bundle"
        try FileManager.default.createDirectory(
            at: packageURL.appending(path: bundleRelativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Installable",
            version: version,
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleRelativePath
        )
        try JSONEncoder().encode(manifest).write(to: packageURL.appending(path: "plugin.json"))
        return packageURL
    }

    private func makeCatalogEntry(id: String, version: String) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Installable",
            summary: "Available from the verified catalog.",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
    }
}

@MainActor
private struct BackupCatalogProvider: PluginCatalogProviding {
    let entries: [PluginCatalogEntry]

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.backup-tests",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "0.1.0",
                plugins: entries
            ),
            sourceURL: URL(string: "https://example.com/catalog.json")!,
            sourceKind: .production,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private struct BackupPackageResolver: PluginPackageResolving {
    let packagesByID: [String: URL]

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        guard let packageURL = packagesByID[entry.id] else {
            throw PluginCatalogManagerError.catalogEntryNotFound(entry.id)
        }

        return packageURL
    }
}

@MainActor
private final class BackupDynamicPluginLoader: DynamicPluginLoading {
    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        records.map { record in
            DynamicPluginLoadResult(
                record: record,
                plugins: [BackupTestPlugin(id: record.id, order: 10, shortcutID: "toggle")],
                errorMessage: nil
            )
        }
    }
}

@MainActor
private final class BackupTestPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int, shortcutID: String) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: .blue,
            order: order,
            defaultDescription: id
        )
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: shortcutID,
                title: shortcutID,
                description: shortcutID,
                actionID: shortcutID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }
}
