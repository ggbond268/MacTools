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

    func testAutomaticBackupsDefaultToEnabledAndPersistTheToggle() {
        let defaults = makeDefaults()
        let first = AutomaticPreferencesBackupCoordinator(userDefaults: defaults)

        XCTAssertTrue(first.isEnabled)
        first.setEnabled(false)

        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(
            AutomaticPreferencesBackupCoordinator(userDefaults: defaults).isEnabled
        )
    }

    func testStatusFormattingUsesAppLocaleForPluralCountsAndSizes() {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer {
            PluginRuntimeLocalization.source.setPreference(originalPreference)
        }

        let englishSize = PreferencesBackupStatusFormatter.byteCount(
            159_000,
            locale: Locale(identifier: "en")
        )
        let frenchSize = PreferencesBackupStatusFormatter.byteCount(
            159_000,
            locale: Locale(identifier: "fr")
        )
        XCTAssertTrue(englishSize.lowercased().contains("kb"))
        XCTAssertTrue(frenchSize.contains("ko"))

        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let englishRelativeDate = PreferencesBackupStatusFormatter.relativeDate(
            referenceDate.addingTimeInterval(-10 * 60),
            relativeTo: referenceDate,
            locale: Locale(identifier: "en"),
            justNow: "just now"
        )
        let englishJustNow = PreferencesBackupStatusFormatter.relativeDate(
            referenceDate.addingTimeInterval(-30),
            relativeTo: referenceDate,
            locale: Locale(identifier: "en"),
            justNow: "just now"
        )
        let futureDate = PreferencesBackupStatusFormatter.relativeDate(
            referenceDate.addingTimeInterval(10 * 60),
            relativeTo: referenceDate,
            locale: Locale(identifier: "en"),
            justNow: "just now"
        )
        let simplifiedChineseRelativeDate = PreferencesBackupStatusFormatter.relativeDate(
            referenceDate.addingTimeInterval(-2 * 24 * 60 * 60),
            relativeTo: referenceDate,
            locale: Locale(identifier: "zh-Hans"),
            justNow: "刚刚"
        )
        XCTAssertTrue(englishRelativeDate.contains("10 min"))
        XCTAssertTrue(englishRelativeDate.lowercased().contains("ago"))
        XCTAssertTrue(englishJustNow.lowercased().contains("now"))
        XCTAssertEqual(futureDate, "just now")
        XCTAssertTrue(simplifiedChineseRelativeDate.contains("2"))
        XCTAssertTrue(simplifiedChineseRelativeDate.contains("天前"))

        PluginRuntimeLocalization.source.setPreference("ru")
        let russian = AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.automatic.history",
            defaultValue: "%d backups · %@",
            count: 21,
            englishSize
        )
        XCTAssertTrue(russian.contains("21 копия"))

        PluginRuntimeLocalization.source.setPreference("ar")
        let arabic = AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.automatic.history",
            defaultValue: "%d backups · %@",
            count: 2,
            englishSize
        )
        XCTAssertTrue(arabic.contains("نسختان احتياطيتان"))

        PluginRuntimeLocalization.source.setPreference("zh-Hans")
        let simplifiedChinese = AppL10n.preferencesBackupPluralFormat(
            "preferencesBackup.automatic.history",
            defaultValue: "%d backups · %@",
            count: 14,
            englishSize
        )
        XCTAssertTrue(simplifiedChinese.contains("14 个备份"))
    }

    func testStoreDeduplicatesSnapshotsThatOnlyDifferByExportDate() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(30)

        XCTAssertCreated(try store.write(makeBackup(marker: "same", date: firstDate), now: firstDate))
        XCTAssertUnchanged(try store.write(makeBackup(marker: "same", date: secondDate), now: secondDate))

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        _ = try PreferencesBackup.decodeJSON(Data(contentsOf: files[0]))
    }

    func testStoreDeduplicatesPluginJSONThatOnlyDiffersByEncodingOrder() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(30)
        let firstPluginData = Data(#"{"enabled":true,"items":[{"b":2,"a":1}]}"#.utf8)
        let secondPluginData = Data(#"{"items":[{"a":1,"b":2}],"enabled":true}"#.utf8)

        XCTAssertCreated(
            try store.write(
                makeBackup(
                    marker: "same",
                    date: firstDate,
                    pluginPreferences: ["test-plugin": firstPluginData]
                ),
                now: firstDate
            )
        )
        XCTAssertUnchanged(
            try store.write(
                makeBackup(
                    marker: "same",
                    date: secondDate,
                    pluginPreferences: ["test-plugin": secondPluginData]
                ),
                now: secondDate
            )
        )

        XCTAssertEqual(try backupFiles(in: directory).count, 1)
    }

    func testStoreKeepsSemanticallyChangedPluginJSON() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(30)

        XCTAssertCreated(
            try store.write(
                makeBackup(
                    marker: "same",
                    pluginPreferences: ["test-plugin": Data(#"{"enabled":true}"#.utf8)]
                ),
                now: firstDate
            )
        )
        XCTAssertCreated(
            try store.write(
                makeBackup(
                    marker: "same",
                    pluginPreferences: ["test-plugin": Data(#"{"enabled":false}"#.utf8)]
                ),
                now: secondDate
            )
        )

        XCTAssertEqual(try backupFiles(in: directory).count, 2)
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

    func testStoreRejectsOlderRevisionAfterNewerWriteFailsPastAdmission() async throws {
        let directory = makeTemporaryDirectoryURL()
        let oldWriteEntered = DispatchSemaphore(value: 0)
        let releaseOldWrite = DispatchSemaphore(value: 0)
        let store = AutomaticPreferencesBackupStore(
            directoryURL: directory,
            beforeVersionedWrite: { revision in
                guard revision == 1 else { return }
                oldWriteEntered.signal()
                releaseOldWrite.wait()
            },
            afterVersionedFileWrite: { revision in
                guard revision == 2 else { return }
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let oldBackup = makeBackup(marker: "old")
        let oldTask = Task.detached {
            try store.writeIfCurrent(
                oldBackup,
                relevantRevision: 1
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
        XCTAssertThrowsError(
            try store.writeIfCurrent(
                makeBackup(marker: "new"),
                relevantRevision: 2
            )
        )
        releaseOldWrite.signal()
        didReleaseOldWrite = true

        guard case .superseded = try await oldTask.value else {
            return XCTFail("Expected the delayed older revision to remain superseded")
        }
        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["new"])
        XCTAssertEqual(try backupFiles(in: directory).count, 1)
    }

    func testStoreSummaryReportsLatestBackupAndHistorySize() throws {
        let directory = makeTemporaryDirectoryURL()
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(10)

        XCTAssertCreated(try store.write(makeBackup(marker: "first"), now: firstDate))
        XCTAssertCreated(try store.write(makeBackup(marker: "second"), now: secondDate))

        let summary = try store.summary()
        let files = try backupFiles(in: directory)
        let expectedSize = try files.reduce(0) { total, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return total + (values.fileSize ?? 0)
        }
        XCTAssertEqual(summary.latestBackupDate, secondDate)
        XCTAssertEqual(summary.snapshotCount, 2)
        XCTAssertEqual(summary.totalSize, expectedSize)
    }

    func testAutomaticBackupFileNameUsesReadableLocalDateAndTime() {
        let name = AutomaticPreferencesBackupStore.makeFileName(
            date: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: -5 * 60 * 60)!,
            uniqueIdentifier: "UNIQUE"
        )

        XCTAssertEqual(
            name,
            "MacTools Backup 1969-12-31 19-00-00.000 - UNIQUE.json"
        )
    }

    func testStoreContinuesToRecognizeLegacyAutomaticBackupFileNames() throws {
        let directory = makeTemporaryDirectoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = AutomaticPreferencesBackupStore(directoryURL: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let backup = makeBackup(marker: "legacy", date: date)
        let legacyURL = directory.appendingPathComponent(
            "MacTools-Automatic-Backup-2023-11-14T22-13-20.000Z-LEGACY.json"
        )
        try backup.encodedJSON().write(to: legacyURL)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: legacyURL.path
        )

        XCTAssertUnchanged(
            try store.write(
                makeBackup(marker: "legacy", date: date.addingTimeInterval(30)),
                now: date.addingTimeInterval(30)
            )
        )
        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.lastPathComponent, legacyURL.lastPathComponent)
    }

    func testGFSRetentionKeepsOneSnapshotPerOlderBucket() {
        let now = Date(timeIntervalSince1970: 1_704_110_400)
        let records = [
            record("recent-a", age: 5 * 60, now: now),
            record("recent-b", age: 45 * 60, now: now),
            record("hour-new", age: 2 * 60 * 60 + 5 * 60, now: now),
            record("hour-old", age: 2 * 60 * 60 + 45 * 60, now: now),
            record("hour-three", age: 3 * 60 * 60 + 5 * 60, now: now),
            record("day-new", age: 2 * 24 * 60 * 60, now: now),
            record("day-old", age: 2 * 24 * 60 * 60 + 60 * 60, now: now),
            record("day-three", age: 3 * 24 * 60 * 60, now: now),
            record("week-new", age: 40 * 24 * 60 * 60, now: now),
            record("week-old", age: 41 * 24 * 60 * 60, now: now),
            record("week-other", age: 50 * 24 * 60 * 60, now: now),
        ]

        let retainedNames = Set(
            AutomaticPreferencesBackupStore.retainedRecords(from: records, now: now)
                .map(\.url.lastPathComponent)
        )

        XCTAssertTrue(retainedNames.isSuperset(of: [
            "recent-a", "recent-b", "hour-new", "hour-three",
            "day-new", "day-three", "week-new", "week-other",
        ]))
        XCTAssertFalse(retainedNames.contains("hour-old"))
        XCTAssertFalse(retainedNames.contains("day-old"))
        XCTAssertFalse(retainedNames.contains("week-old"))
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

    func testCoordinatorPublishesSummaryAfterCreatedUnchangedAndSafetyWrites() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory)
        )
        var marker = "first"
        var summaries: [AutomaticPreferencesBackupSummary] = []
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: marker)
        }
        coordinator.summaryHandler = { summaries.append($0) }

        XCTAssertCreated(try await coordinator.createBackupNow())
        XCTAssertEqual(summaries.last?.snapshotCount, 1)

        XCTAssertUnchanged(try await coordinator.createBackupNow())
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.last?.snapshotCount, 1)

        marker = "second"
        try coordinator.createSafetySnapshotBeforeImport()
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(summaries.last?.snapshotCount, 2)
    }

    func testCoordinatorBuildsOneSnapshotAfterAChangeBurst() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(40)
        )
        var snapshotCount = 0
        coordinator.snapshotProvider = { [unowned self] in
            snapshotCount += 1
            return self.makeBackup(marker: "burst")
        }

        for _ in 0 ..< 10 {
            coordinator.committedPreferencesDidChange()
        }
        XCTAssertEqual(snapshotCount, 0)

        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(try backupFiles(in: directory).count, 1)
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

    func testTerminationWithoutRelevantPendingChangeDoesNotBuildSnapshot() throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .seconds(60)
        )
        var snapshotCount = 0
        coordinator.snapshotProvider = { [unowned self] in
            snapshotCount += 1
            return self.makeBackup(marker: "termination")
        }

        coordinator.flushPendingBackupBeforeTermination()

        XCTAssertEqual(snapshotCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testManualBackupCompletesPendingRelevantRevision() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .seconds(60)
        )
        var snapshotCount = 0
        coordinator.snapshotProvider = { [unowned self] in
            snapshotCount += 1
            return self.makeBackup(marker: "manual")
        }

        coordinator.committedPreferencesDidChange()
        XCTAssertCreated(try await coordinator.createBackupNow())
        coordinator.flushPendingBackupBeforeTermination()

        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(try backupFiles(in: directory).count, 1)
    }

    func testFailedManualBackupRearmsPendingAutomaticBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        coordinator.committedPreferencesDidChange()

        do {
            _ = try await coordinator.createBackupNow()
            XCTFail("Expected a missing snapshot provider to fail")
        } catch {}

        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: "automatic-retry")
        }
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["automatic-retry"])
    }

    func testFailedSafetySnapshotRearmsPendingAutomaticBackup() async throws {
        let defaults = makeDefaults()
        let invalidDirectory = makeTemporaryDirectoryURL()
        try Data("not a directory".utf8).write(to: invalidDirectory)
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: invalidDirectory),
            debounceDelay: .milliseconds(30)
        )
        coordinator.snapshotProvider = { [unowned self] in
            self.makeBackup(marker: "safety-retry")
        }
        coordinator.committedPreferencesDidChange()

        XCTAssertThrowsError(try coordinator.createSafetySnapshotBeforeImport())
        try FileManager.default.removeItem(at: invalidDirectory)
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: invalidDirectory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: invalidDirectory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["safety-retry"])
    }

    func testPluginPersistentPreferenceSignalSchedulesBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        let plugin = PersistentPreferenceSignalTestPlugin()
        let host = makeHost(
            defaults: defaults,
            coordinator: coordinator,
            plugins: [plugin]
        )

        plugin.updatePortablePreference("changed")
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginPreferences[plugin.metadata.id], Data("changed".utf8))
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testPluginInitializationPersistenceSchedulesBackupWhenCallbackIsAttached() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        let plugin = PersistentPreferenceSignalTestPlugin(
            initialValue: "migrated",
            persistedDuringInitialization: true
        )
        let host = makeHost(
            defaults: defaults,
            coordinator: coordinator,
            plugins: [plugin]
        )

        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(backup.pluginPreferences[plugin.metadata.id], Data("migrated".utf8))
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testPluginHostCollectsEachPortablePreferencePayloadOncePerBackup() {
        let defaults = makeDefaults()
        let coordinator = AutomaticPreferencesBackupCoordinator(userDefaults: defaults)
        let plugin = CountingPortablePreferencesTestPlugin()
        let host = makeHost(
            defaults: defaults,
            coordinator: coordinator,
            plugins: [plugin]
        )

        _ = host.makePreferencesBackup()

        XCTAssertEqual(plugin.backupRequestCount, 1)
    }

    func testApplicationPreferencePersistenceSchedulesBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        XCTAssertTrue(
            host.setApplicationAppearancePreference(
                rawValue: AppAppearancePreference.dark.rawValue
            )
        )
        for _ in 0 ..< 50 {
            if (try? backupFiles(in: directory).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let file = try XCTUnwrap(backupFiles(in: directory).first)
        let backup = try PreferencesBackup.decodeJSON(Data(contentsOf: file))
        XCTAssertEqual(
            backup.application.appearancePreference,
            AppAppearancePreference.dark.rawValue
        )
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testExcludedDefaultsChangesDoNotPostponeMeaningfulBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(50)
        )
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        XCTAssertTrue(
            host.setApplicationAppearancePreference(
                rawValue: AppAppearancePreference.dark.rawValue
            )
        )
        for index in 0 ..< 8 {
            try await Task.sleep(for: .milliseconds(10))
            defaults.set(index, forKey: "excluded.runtime.history")
        }
        try await Task.sleep(for: .milliseconds(20))

        let files = try backupFiles(in: directory)
        XCTAssertEqual(files.count, 1)
        let backup = try await PreferencesBackup.decodeJSON(contentsOf: files[0])
        XCTAssertEqual(
            backup.application.appearancePreference,
            AppAppearancePreference.dark.rawValue
        )
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testExcludedDefaultsChangesDoNotScheduleBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        var snapshotCount = 0
        coordinator.snapshotProvider = { [unowned self] in
            snapshotCount += 1
            return self.makeBackup(marker: "excluded")
        }
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        // Host startup can durably initialize empty store payloads. Establish a
        // settled baseline before proving unrelated runtime writes are ignored.
        try await Task.sleep(for: .milliseconds(100))
        try? FileManager.default.removeItem(at: directory)
        snapshotCount = 0

        for index in 0 ..< 8 {
            defaults.set(index, forKey: "excluded.runtime.history")
        }
        try await Task.sleep(for: .milliseconds(100))
        coordinator.flushPendingBackupBeforeTermination()

        XCTAssertEqual(snapshotCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(host.automaticPreferencesBackupEnabled)
    }

    func testNoOpApplicationPersistenceDoesNotScheduleBackup() async throws {
        let defaults = makeDefaults()
        let directory = makeTemporaryDirectoryURL()
        let coordinator = AutomaticPreferencesBackupCoordinator(
            userDefaults: defaults,
            store: AutomaticPreferencesBackupStore(directoryURL: directory),
            debounceDelay: .milliseconds(30)
        )
        var snapshotCount = 0
        coordinator.snapshotProvider = { [unowned self] in
            snapshotCount += 1
            return self.makeBackup(marker: "no-op")
        }
        let host = makeHost(defaults: defaults, coordinator: coordinator)

        try await Task.sleep(for: .milliseconds(100))
        try? FileManager.default.removeItem(at: directory)
        snapshotCount = 0

        XCTAssertTrue(
            host.setApplicationAppearancePreference(
                rawValue: AppAppearancePreference.system.rawValue
            )
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(snapshotCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
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
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
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
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
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

    private func XCTAssertUnchanged(
        _ result: AutomaticPreferencesBackupWriteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unchanged = result else {
            return XCTFail("Expected an unchanged backup, got \(result)", file: file, line: line)
        }
    }
}

@MainActor
private final class PersistentPreferenceSignalTestPlugin:
    MacToolsPlugin,
    PluginPortablePreferencesProviding,
    PluginPersistentPreferencesChangeSignaling
{
    let metadata = PluginMetadata(
        id: "persistent-signal-test",
        title: "Persistent Signal Test",
        iconName: "gearshape",
        iconTint: .blue,
        order: 0,
        defaultDescription: "Persistent Signal Test"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()
    private var portablePreference: Data

    init(
        initialValue: String = "initial",
        persistedDuringInitialization: Bool = false
    ) {
        portablePreference = Data(initialValue.utf8)
        if persistedDuringInitialization {
            persistentPreferencesChanges.didPersist()
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        portablePreference
    }

    func restorePortablePreferences(from data: Data) {
        portablePreference = data
    }

    func updatePortablePreference(_ value: String) {
        portablePreference = Data(value.utf8)
        persistentPreferencesChanges.didPersist()
    }
}

@MainActor
private final class CountingPortablePreferencesTestPlugin:
    MacToolsPlugin,
    PluginPortablePreferencesProviding
{
    let metadata = PluginMetadata(
        id: "counting-portable-preferences-test",
        title: "Counting Portable Preferences Test",
        iconName: "gearshape",
        iconTint: .blue,
        order: 0,
        defaultDescription: "Counting Portable Preferences Test"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var backupRequestCount = 0

    func makePortablePreferencesBackup() -> Data? {
        backupRequestCount += 1
        return Data(#"{"enabled":true}"#.utf8)
    }

    func restorePortablePreferences(from data: Data) {}
}
