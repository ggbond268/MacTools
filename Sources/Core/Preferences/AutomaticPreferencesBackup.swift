import Foundation

enum AutomaticPreferencesBackupWriteResult: Equatable, Sendable {
    case created(URL)
    case unchanged(URL?)
}

enum AutomaticPreferencesBackupStoreWriteOutcome: Equatable, Sendable {
    case accepted(AutomaticPreferencesBackupWriteResult)
    case superseded(URL?)
}

struct AutomaticPreferencesBackupRecord: Equatable, Sendable {
    let url: URL
    let date: Date
    let size: Int
}

struct AutomaticPreferencesBackupSummary: Equatable, Sendable {
    static let empty = AutomaticPreferencesBackupSummary(
        latestBackupDate: nil,
        snapshotCount: 0,
        totalSize: 0
    )

    let latestBackupDate: Date?
    let snapshotCount: Int
    let totalSize: Int
}

/// Thread-safe filesystem store used from detached tasks during normal app use
/// and synchronously for the narrow pre-import and termination safety paths.
final class AutomaticPreferencesBackupStore: @unchecked Sendable {
    static let maximumSnapshotCount = 100
    static let maximumTotalSize = 128 * 1024 * 1024

    private static let filePrefix = "MacTools Backup "
    private static let legacyFilePrefix = "MacTools-Automatic-Backup-"
    private let directoryURL: URL
    private let fileManager: FileManager
    private let beforeVersionedWrite: (@Sendable (UInt64) -> Void)?
    private let afterVersionedFileWrite: (@Sendable (UInt64) throws -> Void)?
    private let lock = NSLock()
    // Admission happens under the same lock as the filesystem write so a
    // delayed older task cannot become the newest snapshot after a newer flush.
    private var highestAdmittedRelevantRevision: UInt64 = 0

    init(
        directoryURL: URL = AutomaticPreferencesBackupStore.defaultDirectoryURL(),
        fileManager: FileManager = .default,
        beforeVersionedWrite: (@Sendable (UInt64) -> Void)? = nil,
        afterVersionedFileWrite: (@Sendable (UInt64) throws -> Void)? = nil
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.beforeVersionedWrite = beforeVersionedWrite
        self.afterVersionedFileWrite = afterVersionedFileWrite
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("MacTools", isDirectory: true)
            .appendingPathComponent("Automatic Backups", isDirectory: true)
    }

    func prepareDirectory() throws -> URL {
        try withLock {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return directoryURL
        }
    }

    func write(_ backup: PreferencesBackup, now: Date = .now) throws -> AutomaticPreferencesBackupWriteResult {
        let outcome = try write(
            backup,
            relevantRevision: nil,
            now: now
        )
        guard case let .accepted(result) = outcome else {
            preconditionFailure("Unversioned automatic backup writes cannot be superseded")
        }
        return result
    }

    func writeIfCurrent(
        _ backup: PreferencesBackup,
        relevantRevision: UInt64,
        now: Date = .now
    ) throws -> AutomaticPreferencesBackupStoreWriteOutcome {
        beforeVersionedWrite?(relevantRevision)
        return try write(backup, relevantRevision: relevantRevision, now: now)
    }

    private func write(
        _ backup: PreferencesBackup,
        relevantRevision: UInt64?,
        now: Date
    ) throws -> AutomaticPreferencesBackupStoreWriteOutcome {
        let data = try backup.encodedJSON()
        _ = try PreferencesBackup.decodeJSON(data)

        return try withLock {
            if let relevantRevision {
                if relevantRevision < highestAdmittedRelevantRevision {
                    let latestURL = (try? records().max(by: { $0.date < $1.date }))?.url
                    return .superseded(latestURL)
                }
                // Once admitted, a newer revision remains the ordering
                // watermark even if a later metadata or rotation step fails.
                // Equal revisions may retry the same snapshot.
                highestAdmittedRelevantRevision = max(
                    highestAdmittedRelevantRevision,
                    relevantRevision
                )
            }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let existingRecords = try records()
            if let latest = existingRecords.max(by: { $0.date < $1.date }),
               let latestData = try? boundedData(contentsOf: latest.url),
               let latestBackup = try? PreferencesBackup.decodeJSON(latestData),
               latestBackup.hasSameMeaningfulContent(as: backup) {
                try rotate(existingRecords, now: now)
                return .accepted(.unchanged(latest.url))
            }

            let url = directoryURL.appendingPathComponent(
                Self.makeFileName(date: now),
                isDirectory: false
            )
            try data.write(to: url, options: .atomic)
            if let relevantRevision {
                try afterVersionedFileWrite?(relevantRevision)
            }
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: url.path
            )

            var updatedRecords = existingRecords
            updatedRecords.append(
                AutomaticPreferencesBackupRecord(url: url, date: now, size: data.count)
            )
            try rotate(updatedRecords, now: now)
            return .accepted(.created(url))
        }
    }

    func summary() throws -> AutomaticPreferencesBackupSummary {
        try withLock {
            let records = try records()
            return AutomaticPreferencesBackupSummary(
                latestBackupDate: records.map(\.date).max(),
                snapshotCount: records.count,
                totalSize: records.reduce(0) { $0 + max(0, $1.size) }
            )
        }
    }

    static func retainedRecords(
        from records: [AutomaticPreferencesBackupRecord],
        now: Date,
        maximumCount: Int = maximumSnapshotCount,
        maximumTotalSize: Int = maximumTotalSize
    ) -> [AutomaticPreferencesBackupRecord] {
        precondition(maximumCount > 0)
        precondition(maximumTotalSize > 0)

        let sorted = records.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.url.path < rhs.url.path }
            return lhs.date > rhs.date
        }
        var hourlyBuckets = Set<Date>()
        var dailyBuckets = Set<Date>()
        var weeklyBuckets = Set<String>()
        var retained: [AutomaticPreferencesBackupRecord] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for record in sorted {
            let age = max(0, now.timeIntervalSince(record.date))
            if age < 60 * 60 {
                retained.append(record)
            } else if age < 24 * 60 * 60 {
                let bucket = calendar.dateInterval(of: .hour, for: record.date)?.start
                    ?? record.date
                if hourlyBuckets.insert(bucket).inserted {
                    retained.append(record)
                }
            } else if age < 30 * 24 * 60 * 60 {
                let bucket = calendar.startOfDay(for: record.date)
                if dailyBuckets.insert(bucket).inserted {
                    retained.append(record)
                }
            } else {
                let components = calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear],
                    from: record.date
                )
                let bucket = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
                if weeklyBuckets.insert(bucket).inserted {
                    retained.append(record)
                }
            }
        }

        if retained.count > maximumCount {
            retained.removeLast(retained.count - maximumCount)
        }
        var totalSize = retained.reduce(0) { $0 + max(0, $1.size) }
        while retained.count > 1, totalSize > maximumTotalSize {
            totalSize -= max(0, retained.removeLast().size)
        }
        return retained
    }

    private func records() throws -> [AutomaticPreferencesBackupRecord] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  Self.isAutomaticBackupFileName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey,
                      .fileSizeKey,
                  ]),
                  let date = values.contentModificationDate,
                  let size = values.fileSize
            else {
                return nil
            }
            return AutomaticPreferencesBackupRecord(url: url, date: date, size: size)
        }
    }

    private func rotate(_ records: [AutomaticPreferencesBackupRecord], now: Date) throws {
        let retainedURLs = Set(Self.retainedRecords(from: records, now: now).map(\.url))
        for record in records where !retainedURLs.contains(record.url) {
            try fileManager.removeItem(at: record.url)
        }
    }

    private func boundedData(contentsOf url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= PreferencesBackup.maximumFileSize else {
            throw PreferencesBackupError.fileTooLarge(
                maximumBytes: PreferencesBackup.maximumFileSize
            )
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func makeFileName(
        date: Date,
        timeZone: TimeZone = .current,
        uniqueIdentifier: String = UUID().uuidString
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss.SSS"
        return "\(filePrefix)\(formatter.string(from: date)) - \(uniqueIdentifier).json"
    }

    private static func isAutomaticBackupFileName(_ fileName: String) -> Bool {
        fileName.hasPrefix(filePrefix) || fileName.hasPrefix(legacyFilePrefix)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

@MainActor
final class AutomaticPreferencesBackupCoordinator {
    static let enabledUserDefaultsKey = "preferencesBackup.automatic.enabled"

    private let userDefaults: UserDefaults
    private let store: AutomaticPreferencesBackupStore
    private let debounceDelay: Duration
    private var pendingTask: Task<Void, Never>?
    private var latestRelevantRevision: UInt64 = 0
    private var completedRelevantRevision: UInt64 = 0

    var snapshotProvider: (() -> PreferencesBackup?)?
    var failureHandler: ((Error) -> Void)?
    var summaryHandler: ((AutomaticPreferencesBackupSummary) -> Void)?
    private(set) var isEnabled: Bool

    init(
        userDefaults: UserDefaults,
        store: AutomaticPreferencesBackupStore = AutomaticPreferencesBackupStore(),
        debounceDelay: Duration = .seconds(60)
    ) {
        self.userDefaults = userDefaults
        self.store = store
        self.debounceDelay = debounceDelay
        isEnabled = userDefaults.object(forKey: Self.enabledUserDefaultsKey) == nil
            ? true
            : userDefaults.bool(forKey: Self.enabledUserDefaultsKey)
    }

    deinit {
        pendingTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledUserDefaultsKey)
        if enabled {
            committedPreferencesDidChange()
        } else {
            pendingTask?.cancel()
            pendingTask = nil
        }
    }

    func committedPreferencesDidChange() {
        guard isEnabled else { return }
        latestRelevantRevision &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        ensurePendingBackupScheduled()
    }

    private func ensurePendingBackupScheduled() {
        guard isEnabled,
              pendingTask == nil,
              latestRelevantRevision > completedRelevantRevision else { return }
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceDelay)
                guard !Task.isCancelled else { return }
                pendingTask = nil
                let revision = latestRelevantRevision
                guard let backup = snapshotProvider?() else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let attempt = try await performBackupNow(
                    backup: backup,
                    revision: revision
                )
                if attempt.wasAccepted {
                    completedRelevantRevision = max(completedRelevantRevision, revision)
                }
                reconcilePendingBackup()
            } catch is CancellationError {
                return
            } catch {
                failureHandler?(error)
                reconcilePendingBackup()
            }
        }
    }

    private func reconcilePendingBackup() {
        guard isEnabled,
              latestRelevantRevision > completedRelevantRevision else {
            pendingTask?.cancel()
            pendingTask = nil
            return
        }
        ensurePendingBackupScheduled()
    }

    func createBackupNow() async throws -> AutomaticPreferencesBackupWriteResult {
        pendingTask?.cancel()
        pendingTask = nil
        let revision = latestRelevantRevision
        do {
            guard let backup = snapshotProvider?() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let attempt = try await performBackupNow(
                backup: backup,
                revision: revision
            )
            if attempt.wasAccepted {
                completedRelevantRevision = max(completedRelevantRevision, revision)
            }
            reconcilePendingBackup()
            return attempt.result
        } catch {
            reconcilePendingBackup()
            throw error
        }
    }

    func refreshSummary() async {
        do {
            let summary = try await Task.detached(priority: .utility) { [store] in
                try store.summary()
            }.value
            summaryHandler?(summary)
        } catch {
            failureHandler?(error)
        }
    }

    private func performBackupNow(
        backup providedBackup: PreferencesBackup? = nil,
        revision: UInt64
    ) async throws -> (result: AutomaticPreferencesBackupWriteResult, wasAccepted: Bool) {
        guard let backup = providedBackup ?? snapshotProvider?() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let (outcome, summary) = try await Task.detached(priority: .utility) { [store] in
            let outcome = try store.writeIfCurrent(
                backup,
                relevantRevision: revision
            )
            return (outcome, try? store.summary())
        }.value
        if let summary {
            summaryHandler?(summary)
        }
        switch outcome {
        case let .accepted(result):
            return (result, true)
        case let .superseded(latestURL):
            return (.unchanged(latestURL), false)
        }
    }

    func prepareBackupDirectory() throws -> URL {
        try store.prepareDirectory()
    }

    /// Imports are synchronous at the mutation point, so the safety snapshot
    /// must complete before any existing preference is replaced.
    func createSafetySnapshotBeforeImport() throws {
        pendingTask?.cancel()
        pendingTask = nil
        let revision = latestRelevantRevision
        do {
            guard let backup = snapshotProvider?() else {
                reconcilePendingBackup()
                return
            }
            let outcome = try store.writeIfCurrent(
                backup,
                relevantRevision: revision
            )
            if case .accepted = outcome {
                completedRelevantRevision = max(completedRelevantRevision, revision)
            }
            if let summary = try? store.summary() {
                summaryHandler?(summary)
            }
            reconcilePendingBackup()
        } catch {
            reconcilePendingBackup()
            throw error
        }
    }

    /// AppKit termination does not await asynchronous work. This is the one
    /// shutdown path where the pending snapshot is intentionally flushed inline.
    func flushPendingBackupBeforeTermination() {
        guard isEnabled,
              latestRelevantRevision > completedRelevantRevision else { return }
        pendingTask?.cancel()
        pendingTask = nil
        let revision = latestRelevantRevision
        guard let backup = snapshotProvider?() else { return }
        do {
            let outcome = try store.writeIfCurrent(
                backup,
                relevantRevision: revision
            )
            if case .accepted = outcome {
                completedRelevantRevision = max(completedRelevantRevision, revision)
            }
            if let summary = try? store.summary() {
                summaryHandler?(summary)
            }
        } catch {
            failureHandler?(error)
        }
    }
}
