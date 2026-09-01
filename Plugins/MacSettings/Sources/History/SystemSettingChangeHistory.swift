import Foundation
import MacToolsPluginKit

enum SystemSettingChangeVerification: String, Codable, Sendable {
    case verified
    case unverified
}

struct SystemSettingChange: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let settingID: SystemSettingID
    let settingTitle: String
    let previousValue: SystemSettingValue
    let previousSnapshot: SystemSettingSnapshot?
    let newValue: SystemSettingValue
    let date: Date
    let verification: SystemSettingChangeVerification
    let canRollback: Bool

    init(
        id: UUID = UUID(),
        settingID: SystemSettingID,
        settingTitle: String,
        previousValue: SystemSettingValue,
        newValue: SystemSettingValue,
        date: Date = Date(),
        verification: SystemSettingChangeVerification,
        canRollback: Bool,
        previousSnapshot: SystemSettingSnapshot? = nil
    ) {
        self.id = id
        self.settingID = settingID
        self.settingTitle = settingTitle
        self.previousValue = previousValue
        self.previousSnapshot = previousSnapshot
        self.newValue = newValue
        self.date = date
        self.verification = verification
        self.canRollback = canRollback
    }
}

@MainActor
protocol SystemSettingChangeHistoryStoring: AnyObject {
    func load(referenceDate: Date) -> [SystemSettingChange]
    func append(_ change: SystemSettingChange, referenceDate: Date) -> [SystemSettingChange]
    func clear()
}

@MainActor
final class SystemSettingChangeHistoryStore: SystemSettingChangeHistoryStoring {
    static let maximumCount = 200
    static let maximumAge: TimeInterval = 90 * 24 * 60 * 60

    private enum Key {
        // Pre-release snapshots used a different shape. Leave them untouched, without migration.
        static let history = "change-history-v2"
    }

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
    }

    func load(referenceDate: Date = Date()) -> [SystemSettingChange] {
        let decoded = storage.data(forKey: Key.history).flatMap {
            try? decoder.decode([SystemSettingChange].self, from: $0)
        } ?? []
        let bounded = Self.bounded(decoded, referenceDate: referenceDate)
        if bounded != decoded {
            persist(bounded)
        }
        return bounded
    }

    func append(
        _ change: SystemSettingChange,
        referenceDate: Date = Date()
    ) -> [SystemSettingChange] {
        let updated = Self.bounded(
            [change] + load(referenceDate: referenceDate),
            referenceDate: referenceDate
        )
        persist(updated)
        return updated
    }

    func clear() {
        storage.removeObject(forKey: Key.history)
    }

    static func bounded(
        _ changes: [SystemSettingChange],
        referenceDate: Date
    ) -> [SystemSettingChange] {
        changes
            .filter {
                $0.date <= referenceDate
                    && referenceDate.timeIntervalSince($0.date) <= maximumAge
            }
            .sorted { $0.date > $1.date }
            .prefix(maximumCount)
            .map { $0 }
    }

    private func persist(_ changes: [SystemSettingChange]) {
        guard let data = try? encoder.encode(changes) else { return }
        storage.set(data, forKey: Key.history)
    }
}

@MainActor
final class InMemorySystemSettingChangeHistoryStore: SystemSettingChangeHistoryStoring {
    private(set) var changes: [SystemSettingChange]

    init(changes: [SystemSettingChange] = []) {
        self.changes = changes
    }

    func load(referenceDate: Date) -> [SystemSettingChange] {
        SystemSettingChangeHistoryStore.bounded(changes, referenceDate: referenceDate)
    }

    func append(_ change: SystemSettingChange, referenceDate: Date) -> [SystemSettingChange] {
        changes = SystemSettingChangeHistoryStore.bounded(
            [change] + changes,
            referenceDate: referenceDate
        )
        return changes
    }

    func clear() {
        changes = []
    }
}
