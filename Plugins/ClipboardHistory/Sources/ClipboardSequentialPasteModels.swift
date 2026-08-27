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
    case activeQueueExists
}

struct ClipboardSequentialPasteOperation: Equatable, Sendable {
    let source: ClipboardSequentialPasteSource
    let itemIDs: [UUID]
    let sessionCreatedAt: Date
    let cursor: Int
    let itemID: UUID
}

struct ClipboardSequentialPasteSession: Codable, Equatable, Sendable {
    static let maximumItemCount = 100

    let source: ClipboardSequentialPasteSource
    private(set) var itemIDs: [UUID]
    private(set) var statuses: [ClipboardSequentialPasteItemStatus]
    private(set) var cursor: Int
    let createdAt: Date
    private(set) var lastActivityAt: Date

    private enum CodingKeys: String, CodingKey {
        case source
        case itemIDs
        case statuses
        case cursor
        case createdAt
        case lastActivityAt
    }

    init(
        source: ClipboardSequentialPasteSource,
        itemIDs: [UUID],
        createdAt: Date = Date()
    ) throws {
        let uniqueItemIDs = Self.unique(itemIDs)
        guard !uniqueItemIDs.isEmpty else {
            throw ClipboardSequentialQueueError.empty
        }
        guard uniqueItemIDs.count <= Self.maximumItemCount else {
            throw ClipboardSequentialQueueError.exceedsMaximumItemCount(
                maximum: Self.maximumItemCount
            )
        }
        self.source = source
        self.itemIDs = uniqueItemIDs
        statuses = Array(repeating: .pending, count: uniqueItemIDs.count)
        cursor = 0
        self.createdAt = createdAt
        lastActivityAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(ClipboardSequentialPasteSource.self, forKey: .source)
        let itemIDs = try container.decode([UUID].self, forKey: .itemIDs)
        let statuses = try container.decode(
            [ClipboardSequentialPasteItemStatus].self,
            forKey: .statuses
        )
        let cursor = try container.decode(Int.self, forKey: .cursor)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        guard !itemIDs.isEmpty,
              itemIDs.count <= Self.maximumItemCount,
              Set(itemIDs).count == itemIDs.count,
              statuses.count == itemIDs.count,
              (0...itemIDs.count).contains(cursor),
              statuses.prefix(cursor).allSatisfy({ $0 != .pending }) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid sequential paste session"
                )
            )
        }
        self.source = source
        self.itemIDs = itemIDs
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
            source: source,
            itemIDs: itemIDs,
            sessionCreatedAt: createdAt,
            cursor: cursor,
            itemID: itemID
        )
    }

    func matches(_ operation: ClipboardSequentialPasteOperation) -> Bool {
        source == operation.source
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
}

@MainActor
protocol ClipboardSequentialPasteSessionPersisting: AnyObject {
    func loadExplicitSession() -> ClipboardSequentialPasteSession?
    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?)
}

@MainActor
final class ClipboardSequentialPasteMemoryStore: ClipboardSequentialPasteSessionPersisting {
    private(set) var session: ClipboardSequentialPasteSession?

    init(session: ClipboardSequentialPasteSession? = nil) {
        self.session = session
    }

    func loadExplicitSession() -> ClipboardSequentialPasteSession? { session }
    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?) {
        self.session = session
    }
}
