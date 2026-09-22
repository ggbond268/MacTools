import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AutomaticPreferencesBackupTests: XCTestCase {
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

    func testStoreWritesChangedSnapshotsAtomicallyAndKeepsThemImportable() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(10)

        XCTAssertCreated(try store.write(makeBackup(marker: "first", date: firstDate), now: firstDate))
        XCTAssertCreated(try store.write(makeBackup(marker: "second", date: secondDate), now: secondDate))

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, PreferencesBackup.maximumFileSize)
            _ = try PreferencesBackup.decodeJSON(data)
        }
    }

    func testStoreRejectsOlderRevisionThatArrivesAfterNewerSnapshot() async throws {
        let directory = makeTemporaryDirectoryURL()
        let oldWriteEntered = DispatchSemaphore(value: 0)
        let releaseOldWrite = DispatchSemaphore(value: 0)
        let store = AutomaticPreferencesBackupStore(
            directoryURL: directory,
            beforeVersionedWrite: { revision in
                guard revision == 1 else { return }
                oldWriteEntered.signal()
                releaseOldWrite.wait()
            }
        )
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldBackup = makeBackup(marker: "old")
        let newBackup = makeBackup(marker: "new")
        let oldTask = Task.detached {
            try store.writeIfCurrent(
                oldBackup,
                relevantRevision: 1,
                now: baseDate.addingTimeInterval(60)
            )
        }
        var didReleaseOldWrite = false
        defer {
            if !didReleaseOldWrite {
                releaseOldWrite.signal()
            }
        }

        let oldWriteDidEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: oldWriteEntered.wait(timeout: .now() + 1) == .success
                )
            }
        }
        guard oldWriteDidEnter else {
            releaseOldWrite.signal()
            _ = try? await oldTask.value
            return XCTFail("Older write did not reach the controlled admission point")
        }
        let newerOutcome = try store.writeIfCurrent(
            newBackup,
            relevantRevision: 2,
            now: baseDate
        )
        releaseOldWrite.signal()
        didReleaseOldWrite = true
        let olderOutcome = try await oldTask.value

        guard case .accepted(.created) = newerOutcome else {
            return XCTFail("Expected the newer revision to be accepted")
        }
        guard case .superseded = olderOutcome else {
            return XCTFail("Expected the delayed older revision to be superseded")
        }
        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["new"])
        XCTAssertEqual(try backupFiles(in: directory).count, 1)
    }

    func testRetentionAppliesCountAndTotalSizeCapsToOldestSnapshots() {
        XCTAssertEqual(PreferencesBackup.maximumFileSize, 16 * 1024 * 1024)
        XCTAssertEqual(
            AutomaticPreferencesBackupStore.maximumTotalSize,
            128 * 1024 * 1024
        )

        let now = Date(timeIntervalSince1970: 1_704_110_400)
        let countRecords = (0 ..< 120).map { index in
            record("count-\(index)", age: TimeInterval(index), now: now, size: 1)
        }
        let countRetained = AutomaticPreferencesBackupStore.retainedRecords(
            from: countRecords,
            now: now
        )
        XCTAssertEqual(countRetained.count, 100)
        XCTAssertEqual(countRetained.first?.url.lastPathComponent, "count-0")
        XCTAssertEqual(countRetained.last?.url.lastPathComponent, "count-99")

        let largeRecords = (0 ..< 9).map { index in
            record(
                "large-\(index)",
                age: TimeInterval(index),
                now: now,
                size: PreferencesBackup.maximumFileSize
            )
        }
        let sizeRetained = AutomaticPreferencesBackupStore.retainedRecords(
            from: largeRecords,
            now: now
        )
        XCTAssertEqual(sizeRetained.count, 8)
        XCTAssertLessThanOrEqual(
            sizeRetained.reduce(0) { $0 + $1.size },
            AutomaticPreferencesBackupStore.maximumTotalSize
        )
    }

    func testCoordinatorDebouncesRepeatedPreferenceChanges() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        var marker = "first"
        var publishedSummary: AutomaticPreferencesBackupSummary?
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: marker)
        }
        coordinator.summaryHandler = { publishedSummary = $0 }

        coordinator.committedPreferencesDidChange()
        marker = "second"
        coordinator.committedPreferencesDidChange()
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        let backup = try await PreferencesBackup.decodeJSON(contentsOf: files[0])
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["second"])
        XCTAssertEqual(publishedSummary?.snapshotCount, 1)
    }

    func testFailedAutomaticAttemptRearmsDirtyRevisionWithoutAnotherChange() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        var snapshotAttempts = 0
        var failureCount = 0
        coordinator.snapshotProvider = { [unowned self] in
            snapshotAttempts += 1
            guard snapshotAttempts > 1 else { return nil }
            return self.makeBackup(marker: "automatic-retry")
        }
        coordinator.failureHandler = { _ in failureCount += 1 }

        coordinator.committedPreferencesDidChange()
        for _ in 0 ..< 50 {
            if snapshotAttempts >= 2,
               (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(snapshotAttempts, 2)
        XCTAssertEqual(failureCount, 1)
        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["automatic-retry"])
    }

    func testTerminationFlushesPendingSnapshot() throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .seconds(60)
        )
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: "termination")
        }

        coordinator.committedPreferencesDidChange()
        coordinator.flushPendingBackupBeforeTermination()

        XCTAssertEqual(try backupFiles(in: directory).count, 1)
    }

    func testEveryBuiltInPortablePreferencesPluginSignalsCommittedChanges() {
        for plugin in BuiltInPluginRegistry().makePlugins()
        where plugin is any PluginPortablePreferencesProviding {
            XCTAssertTrue(
                plugin is any PluginPersistentPreferencesChangeSignaling,
                "\(plugin.metadata.id) exports portable preferences but cannot signal persistence"
            )
        }
    }

    func testImportCreatesImmediateSafetySnapshotBeforeOverwritingPreferences() throws {
        let defaults = makeDefaults()
        defaults.set(
            AppAppearancePreference.dark.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .seconds(60)
        )
        coordinator.setEnabled(false)
        let host = makeHost(defaults: defaults, coordinator: coordinator)
        let imported = makeBackup(
            marker: "imported",
            appearance: .light
        )

        _ = try host.importPreferences(imported)

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        let safetyBackup = try PreferencesBackup.decodeJSON(Data(contentsOf: files[0]))
        XCTAssertEqual(
            safetyBackup.application.appearancePreference,
            AppAppearancePreference.dark.rawValue
        )
        XCTAssertEqual(
            AppAppearancePreference.stored(in: defaults),
            .light
        )
    }

    func testSafetySnapshotWriteFailurePreventsImportMutation() throws {
        let defaults = makeDefaults()
        defaults.set(
            AppAppearancePreference.dark.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        let invalidDirectory = makeTemporaryDirectoryURL()
        try Data("not a directory".utf8).write(to: invalidDirectory)
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: invalidDirectory)
        )
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        XCTAssertThrowsError(
            try host.importPreferences(makeBackup(marker: "imported", appearance: .light))
        )
        XCTAssertEqual(AppAppearancePreference.stored(in: defaults), .dark)
    }

    private func makeBackup(
        marker: String,
        date: Date = .now,
        appearance: AppAppearancePreference = .system,
        pluginPreferences: [String: Data] = [:]
    ) -> PreferencesBackup {
        PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: appearance.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: "standard"
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [marker],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: pluginPreferences,
            exportedAt: date
        )
    }

    private func makeHost(
        defaults: UserDefaults,
        coordinator: AutomaticPreferencesBackupCoordinator,
        plugins: [any MacToolsPlugin] = []
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            automaticPreferencesBackupCoordinator: coordinator,
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AutomaticPreferencesBackupTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticPreferencesBackupTests-\(UUID().uuidString)")
        temporaryURLs.append(url)
        return url
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func record(
        _ name: String,
        age: TimeInterval,
        now: Date,
        size: Int = 1
    ) -> AutomaticPreferencesBackupRecord {
        AutomaticPreferencesBackupRecord(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            date: now.addingTimeInterval(-age),
            size: size
        )
    }

    private func XCTAssertCreated(
        _ result: AutomaticPreferencesBackupWriteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .created = result else {
            return XCTFail("Expected a created backup, got \(result)", file: file, line: line)
        }
    }

}
