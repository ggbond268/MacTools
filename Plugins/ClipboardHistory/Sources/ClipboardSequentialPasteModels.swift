import Foundation

enum ClipboardSequentialPasteSource: String, Codable, Equatable, Sendable {
    case explicitQueue
    case recentHistory
}

enum ClipboardSequentialPasteItemStatus: String, Codable, Equatable, Sendable {
    case pending
    case pasted
    case skipped
    case unavailable
}

enum ClipboardSequentialQueueError: Error, Equatable, Sendable {
    case empty
    case exceedsMaximumItemCount(maximum: Int)
    case exceedsMaximumPayloadByteCount(maximum: Int)
    case activeQueueExists
}

struct ClipboardSequentialPasteSnapshot: Codable, Equatable, Sendable {
    let sourceItemID: UUID
    let payload: ClipboardHistoryPayload
    let expandsSnippetVariables: Bool

    var payloadByteCount: Int { payload.byteCount }
}

struct ClipboardSequentialPasteOperation: Equatable, Sendable {
    let sessionID: UUID
    let source: ClipboardSequentialPasteSource
    let itemIDs: [UUID]
    let sessionCreatedAt: Date
    let cursor: Int
    let itemID: UUID
    let snapshot: ClipboardSequentialPasteSnapshot?
}

struct ClipboardSequentialPasteSession: Codable, Equatable, Sendable {
    static let maximumItemCount = 100
    static let maximumPayloadByteCount = 64 * 1_024 * 1_024

    let id: UUID
    let source: ClipboardSequentialPasteSource
    private(set) var itemIDs: [UUID]
    private(set) var snapshots: [ClipboardSequentialPasteSnapshot]?
    private(set) var statuses: [ClipboardSequentialPasteItemStatus]
    private(set) var cursor: Int
    let createdAt: Date
    private(set) var lastActivityAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case itemIDs
        case snapshots
        case statuses
        case cursor
        case createdAt
        case lastActivityAt
    }

    init(
        recentHistoryItemIDs itemIDs: [UUID],
        createdAt: Date = Date()
    ) throws {
        let uniqueItemIDs = Self.unique(itemIDs)
        try Self.validateItemCount(uniqueItemIDs.count)
        id = UUID()
        source = .recentHistory
        self.itemIDs = uniqueItemIDs
        snapshots = nil
        statuses = Array(repeating: .pending, count: uniqueItemIDs.count)
        cursor = 0
        self.createdAt = createdAt
        lastActivityAt = createdAt
    }

    init(
        explicitSnapshots snapshots: [ClipboardSequentialPasteSnapshot],
        createdAt: Date = Date()
    ) throws {
        var seen = Set<UUID>()
        let uniqueSnapshots = snapshots.filter { seen.insert($0.sourceItemID).inserted }
        try Self.validateItemCount(uniqueSnapshots.count)
        let totalByteCount = uniqueSnapshots.reduce(into: 0) { total, snapshot in
            total += snapshot.payloadByteCount
        }
        guard totalByteCount <= Self.maximumPayloadByteCount else {
            throw ClipboardSequentialQueueError.exceedsMaximumPayloadByteCount(
                maximum: Self.maximumPayloadByteCount
            )
        }
        id = UUID()
        source = .explicitQueue
        itemIDs = uniqueSnapshots.map(\.sourceItemID)
        self.snapshots = uniqueSnapshots
        statuses = Array(repeating: .pending, count: uniqueSnapshots.count)
        cursor = 0
        self.createdAt = createdAt
        lastActivityAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let source = try container.decode(ClipboardSequentialPasteSource.self, forKey: .source)
        let itemIDs = try container.decode([UUID].self, forKey: .itemIDs)
        let snapshots = try container.decodeIfPresent(
            [ClipboardSequentialPasteSnapshot].self,
            forKey: .snapshots
        )
        let statuses = try container.decode(
            [ClipboardSequentialPasteItemStatus].self,
            forKey: .statuses
        )
        let cursor = try container.decode(Int.self, forKey: .cursor)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        let snapshotsAreValid = switch source {
        case .explicitQueue:
            snapshots?.map(\.sourceItemID) == itemIDs
                && (snapshots?.reduce(into: 0) { $0 += $1.payloadByteCount } ?? .max)
                    <= Self.maximumPayloadByteCount
        case .recentHistory:
            snapshots == nil
        }
        guard !itemIDs.isEmpty,
              itemIDs.count <= Self.maximumItemCount,
              Set(itemIDs).count == itemIDs.count,
              statuses.count == itemIDs.count,
              (0...itemIDs.count).contains(cursor),
              statuses.prefix(cursor).allSatisfy({ $0 != .pending }),
              snapshotsAreValid else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid sequential paste session"
                )
            )
        }
        self.id = id
        self.source = source
        self.itemIDs = itemIDs
        self.snapshots = snapshots
        self.statuses = statuses
        self.cursor = cursor
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    var totalCount: Int { itemIDs.count }
    var nextItemID: UUID? { itemIDs.indices.contains(cursor) ? itemIDs[cursor] : nil }
    var currentPosition: Int? { nextItemID == nil ? nil : cursor + 1 }
    var completedCount: Int {
        statuses.lazy.filter { $0 == .pasted || $0 == .skipped }.count
    }
    var isComplete: Bool { cursor >= itemIDs.count }
    var remainingCount: Int { max(0, itemIDs.count - cursor) }

    var nextOperation: ClipboardSequentialPasteOperation? {
        guard let itemID = nextItemID else { return nil }
        return ClipboardSequentialPasteOperation(
            sessionID: id,
            source: source,
            itemIDs: itemIDs,
            sessionCreatedAt: createdAt,
            cursor: cursor,
            itemID: itemID,
            snapshot: snapshots?[cursor]
        )
    }

    func matches(_ operation: ClipboardSequentialPasteOperation) -> Bool {
        id == operation.sessionID
            && source == operation.source
            && itemIDs == operation.itemIDs
            && createdAt == operation.sessionCreatedAt
            && cursor == operation.cursor
            && nextItemID == operation.itemID
    }

    mutating func recordSuccessfulPaste(now: Date = Date()) {
        guard statuses.indices.contains(cursor) else { return }
        statuses[cursor] = .pasted
        cursor += 1
        lastActivityAt = now
    }

    mutating func skip(now: Date = Date()) {
        guard statuses.indices.contains(cursor) else { return }
        statuses[cursor] = .skipped
        cursor += 1
        lastActivityAt = now
    }

    mutating func markCurrentUnavailable(now: Date = Date()) {
        guard statuses.indices.contains(cursor) else { return }
        statuses[cursor] = .unavailable
        cursor += 1
        lastActivityAt = now
    }

    mutating func moveToPrevious(now: Date = Date()) {
        guard cursor > 0 else { return }
        cursor -= 1
        lastActivityAt = now
    }

    mutating func restart(now: Date = Date()) {
        statuses = Array(repeating: .pending, count: itemIDs.count)
        cursor = 0
        lastActivityAt = now
    }

    private static func unique(_ itemIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return itemIDs.filter { seen.insert($0).inserted }
    }

    private static func validateItemCount(_ count: Int) throws {
        guard count > 0 else { throw ClipboardSequentialQueueError.empty }
        guard count <= maximumItemCount else {
            throw ClipboardSequentialQueueError.exceedsMaximumItemCount(maximum: maximumItemCount)
        }
    }
}

protocol ClipboardSequentialPasteSessionPersisting: Sendable {
    func loadExplicitSession() async throws -> ClipboardSequentialPasteSession?
    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?) async throws
}

actor ClipboardSequentialPasteMemoryStore: ClipboardSequentialPasteSessionPersisting {
    private(set) var session: ClipboardSequentialPasteSession?

    init(session: ClipboardSequentialPasteSession? = nil) {
        self.session = session
    }

    func loadExplicitSession() async throws -> ClipboardSequentialPasteSession? { session }
    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?) async throws {
        self.session = session
    }
}
