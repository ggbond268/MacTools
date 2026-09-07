import Foundation

/// Deletion audit log (design §7.8).
///
/// Append-only JSONL; rotate to `.1` at 5MB, keep 2 generations (current + one rotated).
/// Log path lives under the plugin support directory, protected by the SafetyPolicy "cleanup tool state" branch.
final class DiskCleanAuditLog: @unchecked Sendable {
    struct Record: Codable, Equatable, Sendable {
        enum Action: String, Codable, Sendable {
            case trash
            case delete
            /// Scan-level events: circuit breakers, thread abandonment, reconciliation results.
            case scanEvent
            /// Run-level summary event.
            case runSummary
        }

        let timestamp: Date
        let action: Action
        let runID: String?
        let targetID: String?
        let legacyRuleID: String?
        let category: String?
        let path: String?
        let stagedName: String?
        let estimatedBytes: Int64?
        /// ok / skipped / failed / partiallyDeleted / rollbackBlocked / reconciled…
        let status: String
        let skipReason: String?
        let error: String?

        // Run-level summary fields
        let categoriesCleaned: [String]?
        let itemsRemoved: Int?
        let bytesRemoved: Int64?
        let errorsEncountered: [String]?
        let isTrash: Bool?

        init(
            timestamp: Date,
            action: Action,
            runID: String? = nil,
            targetID: String? = nil,
            legacyRuleID: String? = nil,
            category: String? = nil,
            path: String? = nil,
            stagedName: String? = nil,
            estimatedBytes: Int64? = nil,
            status: String,
            skipReason: String? = nil,
            error: String? = nil,
            categoriesCleaned: [String]? = nil,
            itemsRemoved: Int? = nil,
            bytesRemoved: Int64? = nil,
            errorsEncountered: [String]? = nil,
            isTrash: Bool? = nil
        ) {
            self.timestamp = timestamp
            self.action = action
            self.runID = runID
            self.targetID = targetID
            self.legacyRuleID = legacyRuleID
            self.category = category
            self.path = path
            self.stagedName = stagedName
            self.estimatedBytes = estimatedBytes
            self.status = status
            self.skipReason = skipReason
            self.error = error
            self.categoriesCleaned = categoriesCleaned
            self.itemsRemoved = itemsRemoved
            self.bytesRemoved = bytesRemoved
            self.errorsEncountered = errorsEncountered
            self.isTrash = isTrash
        }
    }

    static let fileName = "audit.jsonl"
    static let rotatedFileName = "audit.jsonl.1"
    /// Rotation threshold. Tests may inject a smaller value.
    let maximumFileSizeBytes: Int

    private let directory: URL
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Same as `DiskCleanStagingJournal`: init does not touch the filesystem; the directory is created on first write.
    init(directory: URL, maximumFileSizeBytes: Int = 5 * 1024 * 1024) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.rotatedFileURL = directory.appendingPathComponent(Self.rotatedFileName)
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Append one record. Audit failure must not block deletion (best effort), but rotation is decided before the append.
    func append(_ record: Record) {
        lock.lock()
        defer { lock.unlock() }

        rotateIfNeeded()
        guard let data = try? encoder.encode(record) else { return }
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([UInt8(ascii: "\n")]))
        } catch {
            // Audit is observability, not a safety barrier; failure must not block deletion.
        }
    }

    /// Read recent records newest-first (cleanup history UI). Spans the current file and one rotated `.1` generation.
    func recentRecords(limit: Int) -> [Record] {
        lock.lock()
        defer { lock.unlock() }

        var records: [Record] = []
        for url in [fileURL, rotatedFileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for lineData in data.split(separator: UInt8(ascii: "\n")) {
                if let record = try? decoder.decode(Record.self, from: Data(lineData)) {
                    records.append(record)
                }
            }
        }
        return Array(records.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// Read recent cleanup runs newest-first, combining explicit run summaries and projecting legacy sessions.
    func recentRuns(limit: Int) -> [DiskCleanRunHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        var allRecords: [Record] = []
        for url in [fileURL, rotatedFileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for lineData in data.split(separator: UInt8(ascii: "\n")) {
                if let record = try? decoder.decode(Record.self, from: Data(lineData)) {
                    allRecords.append(record)
                }
            }
        }

        let summaryRecords = allRecords.filter { $0.action == .runSummary }
        let itemRecords = allRecords.filter { $0.action == .trash || $0.action == .delete }
        let summarizedRunIDs = Set(
            summaryRecords.compactMap(\.runID).filter { !$0.isEmpty }
        )

        var itemRecordsByRunID: [String: [Record]] = [:]
        var unassignedRecords: [Record] = []

        for record in itemRecords {
            if let runID = record.runID, !runID.isEmpty {
                itemRecordsByRunID[runID, default: []].append(record)
            } else {
                unassignedRecords.append(record)
            }
        }

        var runs: [DiskCleanRunHistoryEntry] = []

        for summary in summaryRecords {
            let runID = summary.runID ?? "run-\(summary.timestamp.timeIntervalSince1970)"
            let matchedRecords = itemRecordsByRunID[runID] ?? []
            let matchedItems = DiskCleanCleanupHistoryEntry.entries(from: matchedRecords)
            let hasAttention = (summary.errorsEncountered?.isEmpty == false)
                || summary.status == "partiallyDeleted"
                || summary.status == "rollbackBlocked"
                || matchedItems.contains(where: \.needsAttention)

            runs.append(
                DiskCleanRunHistoryEntry(
                    id: runID,
                    timestamp: summary.timestamp,
                    isTrash: summary.isTrash ?? (summary.action == .trash),
                    status: summary.status,
                    categoriesCleaned: summary.categoriesCleaned ?? [],
                    itemsRemoved: summary.itemsRemoved ?? matchedRecords.filter { $0.status == "ok" }.count,
                    bytesRemoved: summary.bytesRemoved ?? verifiedRemovedBytes(in: matchedRecords),
                    errorsEncountered: summary.errorsEncountered ?? [],
                    needsAttention: hasAttention,
                    itemEntries: matchedItems
                )
            )
        }

        // A process can stop after appending item records but before its final summary. Keep each
        // unmatched run visible so a partial deletion or blocked rollback is never hidden in the
        // default history view. A run ID is supplied by the executor and is therefore stable across
        // refreshes; completed runs remain represented by their authoritative summary above.
        for (runID, records) in itemRecordsByRunID where !summarizedRunIDs.contains(runID) {
            let sortedRecords = records.sorted { $0.timestamp > $1.timestamp }
            guard let latestRecord = sortedRecords.first else { continue }

            let entries = DiskCleanCleanupHistoryEntry.entries(from: sortedRecords)
            let categories = Array(Set(sortedRecords.compactMap(\.category))).sorted()
            let errors = sortedRecords.compactMap(\.error)

            runs.append(
                DiskCleanRunHistoryEntry(
                    id: runID,
                    timestamp: latestRecord.timestamp,
                    isTrash: sortedRecords.allSatisfy { $0.action == .trash },
                    status: "interrupted",
                    categoriesCleaned: categories,
                    itemsRemoved: sortedRecords.filter { $0.status == "ok" }.count,
                    bytesRemoved: verifiedRemovedBytes(in: sortedRecords),
                    errorsEncountered: errors,
                    needsAttention: entries.contains(where: \.needsAttention),
                    itemEntries: entries
                )
            )
        }

        if !unassignedRecords.isEmpty {
            let sortedRecords = unassignedRecords.sorted { $0.timestamp > $1.timestamp }
            var clusters: [[Record]] = []
            var currentCluster: [Record] = []

            for record in sortedRecords {
                if let last = currentCluster.last {
                    if abs(record.timestamp.timeIntervalSince(last.timestamp)) <= 3.0 {
                        currentCluster.append(record)
                    } else {
                        clusters.append(currentCluster)
                        currentCluster = [record]
                    }
                } else {
                    currentCluster = [record]
                }
            }
            if !currentCluster.isEmpty {
                clusters.append(currentCluster)
            }

            for cluster in clusters {
                guard let first = cluster.first else { continue }
                let clusterEntries = DiskCleanCleanupHistoryEntry.entries(from: cluster)
                let isTrash = cluster.contains { $0.action == .trash }
                let categories = Array(Set(cluster.compactMap(\.category))).sorted()
                let removed = cluster.filter { $0.status == "ok" }.count
                let bytes = verifiedRemovedBytes(in: cluster)
                let errors = cluster.compactMap(\.error)
                let hasAttention = clusterEntries.contains(where: \.needsAttention)
                let runID = "session-\(Int(first.timestamp.timeIntervalSince1970))"

                runs.append(
                    DiskCleanRunHistoryEntry(
                        id: runID,
                        timestamp: first.timestamp,
                        isTrash: isTrash,
                        status: errors.isEmpty ? "ok" : "completedWithErrors",
                        categoriesCleaned: categories,
                        itemsRemoved: removed,
                        bytesRemoved: bytes,
                        errorsEncountered: errors,
                        needsAttention: hasAttention,
                        itemEntries: clusterEntries
                    )
                )
            }
        }

        return Array(runs.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// Audit records carry estimated source sizes. Only a verified `ok` record proves that those
    /// bytes were removed; failed, skipped, and partial results must not inflate history totals.
    private func verifiedRemovedBytes(in records: [Record]) -> Int64 {
        records.reduce(into: 0) { total, record in
            guard record.status == "ok", let bytes = record.estimatedBytes else { return }
            total += max(bytes, 0)
        }
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maximumFileSizeBytes else { return }

        try? FileManager.default.removeItem(at: rotatedFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedFileURL)
    }
}


// MARK: - Run-level cleanup history model

struct DiskCleanRunHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date
    let isTrash: Bool
    let status: String
    let categoriesCleaned: [String]
    let itemsRemoved: Int
    let bytesRemoved: Int64
    let errorsEncountered: [String]
    let needsAttention: Bool
    let itemEntries: [DiskCleanCleanupHistoryEntry]

    init(
        id: String,
        timestamp: Date,
        isTrash: Bool,
        status: String,
        categoriesCleaned: [String],
        itemsRemoved: Int,
        bytesRemoved: Int64,
        errorsEncountered: [String] = [],
        needsAttention: Bool = false,
        itemEntries: [DiskCleanCleanupHistoryEntry] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.isTrash = isTrash
        self.status = status
        self.categoriesCleaned = categoriesCleaned
        self.itemsRemoved = itemsRemoved
        self.bytesRemoved = bytesRemoved
        self.errorsEncountered = errorsEncountered
        self.needsAttention = needsAttention
        self.itemEntries = itemEntries
    }
}
