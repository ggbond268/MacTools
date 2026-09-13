import CryptoKit
import Foundation

struct ClipboardBackupRecord: Codable, Sendable {
    enum Table: String, Codable, CaseIterable, Sendable { case items, saved_items }
    var table: Table
    var id: UUID
    var metadata: Data
    var payload: Data

    typealias History = IncrementalEncryptedClipboardHistoryStore.StoredMetadata
    typealias Snippet = IncrementalEncryptedClipboardSavedLibraryStore.StoredMetadata

    var history: History { get throws { try JSONDecoder().decode(History.self, from: metadata) } }
    var snippet: Snippet { get throws { try JSONDecoder().decode(Snippet.self, from: metadata) } }

    func validate(maximumItemBytes: Int) throws -> (history: Int, saved: Int, snippets: Int, bytes: Int, missing: [String]) {
        guard metadata.count <= 1_024 * 1_024, payload.count <= maximumItemBytes * 2 + 1_024 * 1_024 else {
            throw ClipboardBackupError.limitExceeded
        }
        let decoded = try PropertyListDecoder().decode(ClipboardHistoryPayload.self, from: payload)
        guard decoded.byteCount <= maximumItemBytes else { throw ClipboardBackupError.limitExceeded }
        let digest = ClipboardHistoryItem.digest(decoded)
        let missing = decoded.fileURLs.filter { !$0.isFileURL || !FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        switch table {
        case .items:
            let value = try history
            guard value.id == id, value.payloadDigest == digest, value.payloadByteCount == decoded.byteCount,
                  value.kind == decoded.kind, (value.isInHistory ?? true) || value.savedMetadata != nil else {
                throw ClipboardBackupError.invalidArchive
            }
            return ((value.isInHistory ?? true) ? 1 : 0, value.savedMetadata == nil ? 0 : 1, 0, decoded.byteCount, missing)
        case .saved_items:
            let value = try snippet
            guard value.id == id, value.savedKind == .snippet, value.payloadDigest == digest,
                  value.payloadByteCount == decoded.byteCount, value.contentKind == decoded.kind,
                  value.keyword == ClipboardSavedItem.normalizedKeyword(value.keyword) else {
                throw ClipboardBackupError.invalidArchive
            }
            return (0, 0, 1, decoded.byteCount, missing)
        }
    }

    func selected(scope: ClipboardBackupScope) throws -> Self? {
        var record = self
        switch table {
        case .items:
            var value = try history
            value.isInHistory = scope.history && (value.isInHistory ?? true)
            if !scope.saved { value.savedMetadata = nil }
            guard value.isInHistory == true || value.savedMetadata != nil else { return nil }
            record.metadata = try JSONEncoder().encode(value)
        case .saved_items:
            guard scope.snippets else { return nil }
            guard try snippet.savedKind == .snippet else { return nil }
        }
        return record
    }

    func changingID(_ newID: UUID) throws -> Self {
        var record = self
        record.id = newID
        switch table {
        case .items:
            var value = try history
            value.id = newID
            record.metadata = try JSONEncoder().encode(value)
        case .saved_items:
            var value = try snippet
            value.id = newID
            record.metadata = try JSONEncoder().encode(value)
        }
        return record
    }

    func disablingKeyword() throws -> Self {
        var record = self
        var value = try snippet
        value.keyword = nil
        record.metadata = try JSONEncoder().encode(value)
        return record
    }

    /// Equal payloads retain membership, tags, OCR state and the most recent editable metadata.
    func merging(_ local: Self) throws -> Self {
        var record = self
        switch table {
        case .items:
            var value = try history
            let old = try local.history
            value.isInHistory = (value.isInHistory ?? true) || (old.isInHistory ?? true)
            if let incoming = value.savedMetadata, let existing = old.savedMetadata {
                var saved = incoming.updatedAt > existing.updatedAt ? incoming : existing
                saved.tags = Self.unionTags(saved.tags, incoming.tags + existing.tags)
                value.savedMetadata = saved
            } else { value.savedMetadata = value.savedMetadata ?? old.savedMetadata }
            value.capturedAt = min(value.capturedAt, old.capturedAt)
            value.lastUsedAt = [value.lastUsedAt, old.lastUsedAt].compactMap { $0 }.max()
            value.source = value.source ?? old.source
            if let source = value.source {
                value.sourceApplication = source.application
            } else {
                value.sourceApplication = value.sourceApplication ?? old.sourceApplication
            }
            value.imageSearchText = value.imageSearchText ?? old.imageSearchText
            value.hasCompletedImageTextIndexing = (value.hasCompletedImageTextIndexing ?? false) || (old.hasCompletedImageTextIndexing ?? false)
            record.metadata = try JSONEncoder().encode(value)
        case .saved_items:
            let incoming = try snippet
            let old = try local.snippet
            var value = incoming.updatedAt > old.updatedAt ? incoming : old
            value.tags = Self.unionTags(value.tags, incoming.tags + old.tags)
            value.createdAt = min(incoming.createdAt, old.createdAt)
            value.lastUsedAt = [incoming.lastUsedAt, old.lastUsedAt].compactMap { $0 }.max()
            value.imageSearchText = value.imageSearchText ?? old.imageSearchText ?? incoming.imageSearchText
            record.metadata = try JSONEncoder().encode(value)
        }
        return record
    }

    private static func unionTags(_ preferred: [String], _ all: [String]) -> [String] {
        var seen = Set<String>()
        return (preferred + all).filter { seen.insert($0.lowercased()).inserted }
    }

    func canMergeMetadata(with other: Self) throws -> Bool {
        let tags: [String]
        switch table {
        case .items: tags = try (history.savedMetadata?.tags ?? []) + (other.history.savedMetadata?.tags ?? [])
        case .saved_items: tags = try snippet.tags + other.snippet.tags
        }
        // Keep both rows when combining metadata would exceed the library's public limits.
        return Set(tags.map { $0.lowercased() }).count <= ClipboardSavedItem.maximumTagCount
    }

    func hasSameMetadata(as other: Self) throws -> Bool {
        guard table == other.table else { return false }
        switch table {
        case .items: return try history == other.history
        case .saved_items: return try snippet == other.snippet
        }
    }

    func hasSamePayload(as other: Self) throws -> Bool {
        guard table == other.table else { return false }
        // Compare decoded representations: equivalent binary plists need not have identical bytes.
        return try PropertyListDecoder().decode(ClipboardHistoryPayload.self, from: payload)
            == PropertyListDecoder().decode(ClipboardHistoryPayload.self, from: other.payload)
    }
}
