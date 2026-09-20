import Foundation
import MacToolsPluginKit
import SwiftUI

@MainActor
final class ClipboardItemShortcutStore: ObservableObject {
    enum Lifetime: Int, CaseIterable, Identifiable {
        case fiveMinutes = 300
        case oneHour = 3_600
        case oneDay = 86_400
        case untilRemoved = -1

        var id: Int { rawValue }
    }

    enum Source: String, Codable {
        case history
        case saved
        case snippet
    }

    enum PasteFormat: String, Codable, CaseIterable, Hashable, Identifiable {
        case original
        case plainText

        var id: String { rawValue }
    }

    struct Assignment: Codable, Equatable, Identifiable {
        let id: UUID
        let itemID: UUID
        let source: Source
        let pasteFormat: PasteFormat
        let expiresAt: Date?

        var definitionID: String { ClipboardItemShortcutStore.definitionID(for: itemID, pasteFormat: pasteFormat) }

        init(id: UUID, itemID: UUID, source: Source, pasteFormat: PasteFormat, expiresAt: Date?) {
            self.id = id
            self.itemID = itemID
            self.source = source
            self.pasteFormat = pasteFormat
            self.expiresAt = expiresAt
        }

        private enum CodingKeys: String, CodingKey { case id, itemID, source, pasteFormat, expiresAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            itemID = try values.decode(UUID.self, forKey: .itemID)
            source = try values.decode(Source.self, forKey: .source)
            pasteFormat = try values.decodeIfPresent(PasteFormat.self, forKey: .pasteFormat) ?? .original
            expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        }
    }

    private static let storageKey = "itemShortcutAssignments.v1"
    private let storage: any PluginStorage
    private let now: () -> Date
    private var expirationTask: Task<Void, Never>?
    @Published private(set) var assignments: [Assignment]
    var onRemoved: (([Assignment]) -> Void)?
    var onAssignmentsChanged: (() -> Void)?

    init(storage: any PluginStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        if let data = storage.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Assignment].self, from: data) {
            assignments = decoded
        } else {
            assignments = []
        }
        scheduleExpiration()
    }

    nonisolated static func definitionID(for itemID: UUID, pasteFormat: PasteFormat = .original) -> String {
        let prefix = pasteFormat == .plainText ? "item-paste-plain-" : "item-paste-"
        return "\(prefix)\(itemID.uuidString.lowercased())"
    }

    nonisolated static func itemID(for definitionID: String) -> UUID? {
        target(for: definitionID)?.itemID
    }

    nonisolated static func target(for definitionID: String) -> (itemID: UUID, pasteFormat: PasteFormat)? {
        let pasteFormat: PasteFormat = definitionID.hasPrefix("item-paste-plain-") ? .plainText : .original
        let prefix = pasteFormat == .plainText ? "item-paste-plain-" : "item-paste-"
        guard definitionID.hasPrefix(prefix) else { return nil }
        guard let itemID = UUID(uuidString: String(definitionID.dropFirst(prefix.count))) else { return nil }
        return (itemID, pasteFormat)
    }

    func assignment(for itemID: UUID, pasteFormat: PasteFormat = .original) -> Assignment? {
        assignments.first {
            $0.itemID == itemID && $0.pasteFormat == pasteFormat && ($0.expiresAt.map { $0 > now() } ?? true)
        }
    }

    var activeHistoryItemIDs: Set<UUID> {
        let currentDate = now()
        return Set(assignments.lazy.filter {
            $0.source == .history && ($0.expiresAt.map { $0 > currentDate } ?? true)
        }.map(\.itemID))
    }

    func isCurrent(_ id: UUID, itemID: UUID) -> Bool {
        assignments.contains { $0.id == id && $0.itemID == itemID && ($0.expiresAt.map { $0 > now() } ?? true) }
    }

    @discardableResult
    func assign(itemID: UUID, source: Source, pasteFormat: PasteFormat = .original, lifetime: Lifetime?) -> Assignment {
        let previous = assignment(for: itemID, pasteFormat: pasteFormat)
        precondition(lifetime != nil || previous != nil)
        let assignment = Assignment(
            id: UUID(), itemID: itemID, source: source, pasteFormat: pasteFormat,
            expiresAt: lifetime.map { selected in
                selected == .untilRemoved ? nil : now().addingTimeInterval(TimeInterval(selected.rawValue))
            } ?? previous?.expiresAt
        )
        assignments.removeAll { $0.itemID == itemID && $0.pasteFormat == pasteFormat }
        assignments.append(assignment)
        persist()
        scheduleExpiration()
        return assignment
    }

    func restore(_ assignment: Assignment?) {
        guard let assignment else { return }
        assignments.removeAll { $0.itemID == assignment.itemID && $0.pasteFormat == assignment.pasteFormat }
        assignments.append(assignment)
        persist()
        scheduleExpiration()
    }

    @discardableResult
    func remove(itemID: UUID, pasteFormat: PasteFormat? = nil) -> Bool {
        let removed = assignments.filter { $0.itemID == itemID && (pasteFormat == nil || $0.pasteFormat == pasteFormat) }
        guard !removed.isEmpty else { return false }
        onRemoved?(removed)
        assignments.removeAll { $0.itemID == itemID && (pasteFormat == nil || $0.pasteFormat == pasteFormat) }
        persist()
        scheduleExpiration()
        return true
    }

    func removeMissingItems(historyIDs: Set<UUID>, savedIDs: Set<UUID>) {
        removeMissingItems(
            historyIDs: historyIDs,
            savedIDs: savedIDs,
            snippetIDs: savedIDs
        )
    }

    func removeMissingItems(
        historyIDs: Set<UUID>?,
        savedIDs: Set<UUID>?,
        snippetIDs: Set<UUID>?
    ) {
        removeWhere { assignment in
            switch assignment.source {
            case .history: historyIDs.map { !$0.contains(assignment.itemID) } ?? false
            case .saved: savedIDs.map { !$0.contains(assignment.itemID) } ?? false
            case .snippet: snippetIDs.map { !$0.contains(assignment.itemID) } ?? false
            }
        }
    }

    func removeAll() {
        removeWhere { _ in true }
    }

    func expireIfNeeded() {
        removeWhere { $0.expiresAt.map { $0 <= now() } ?? false }
    }

    private func removeWhere(_ predicate: (Assignment) -> Bool) {
        let removed = assignments.filter(predicate)
        guard !removed.isEmpty else { return }
        onRemoved?(removed)
        assignments.removeAll(where: predicate)
        persist()
        scheduleExpiration()
    }

    private func persist() {
        storage.set(try? JSONEncoder().encode(assignments), forKey: Self.storageKey)
        onAssignmentsChanged?()
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        guard let next = assignments.compactMap(\.expiresAt).filter({ $0 > now() }).min() else { return }
        let interval = max(0, next.timeIntervalSince(now()))
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.expireIfNeeded()
        }
    }
}
