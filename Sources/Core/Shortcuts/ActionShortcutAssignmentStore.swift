import Foundation
import MacToolsPluginKit

@MainActor
protocol ActionShortcutAssignmentPersisting: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func data(forKey defaultName: String) -> Data?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: ActionShortcutAssignmentPersisting {}

enum ActionShortcutStoreWriteResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
}

enum ActionShortcutLegacyMigrationResult: Equatable {
    case migrated
    case alreadyMigrated
    case rejected(rollbackSucceeded: Bool)
}

struct ActionShortcutAssignmentRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let reference: ActionReference
    let binding: ShortcutBinding

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        binding: ShortcutBinding
    ) {
        self.id = id
        self.reference = reference
        self.binding = binding
    }
}

@MainActor
final class ActionShortcutAssignmentStore {
    private struct Payload: Codable {
        let version: Int
        let assignments: [ActionShortcutAssignmentRecord]
    }

    private enum DefaultsKey {
        static let payload = "action-shortcuts.assignments"
        static let legacyAppMigration = "action-shortcuts.migrated-app-shortcuts"
        static let legacyPluginMigrationPrefix = "action-shortcuts.migrated-plugin."
    }

    static let maximumAssignmentCount = 512
    private static let currentVersion = 1

    private let defaults: any ActionShortcutAssignmentPersisting
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var loadError: String?
    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.defaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    init(
        defaults: any ActionShortcutAssignmentPersisting,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.defaults = defaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    func assignments() -> [ActionShortcutAssignmentRecord] {
        guard let storedValue = defaults.object(forKey: DefaultsKey.payload) else {
            loadError = nil
            return []
        }
        guard let data = storedValue as? Data else {
            loadError = FeatureL10n.string("快捷键数据无法读取。")
            return []
        }
        do {
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.version == Self.currentVersion,
                  payload.assignments.count <= Self.maximumAssignmentCount,
                  Set(payload.assignments.map(\.id)).count == payload.assignments.count else {
                loadError = FeatureL10n.string("快捷键数据格式无效。")
                return []
            }
            loadError = nil
            return payload.assignments
        } catch {
            loadError = FeatureL10n.string("快捷键数据无法读取。")
            return []
        }
    }

    @discardableResult
    func replaceAll(
        _ assignments: [ActionShortcutAssignmentRecord],
        reportsCommittedChange: Bool = true
    ) -> ActionShortcutStoreWriteResult {
        _ = self.assignments()
        guard loadError == nil else { return .rejected(rollbackSucceeded: true) }
        return replaceAll(
            assignments,
            allowsRecovery: false,
            reportsCommittedChange: reportsCommittedChange
        )
    }

    @discardableResult
    func replaceAllForRecovery(
        _ assignments: [ActionShortcutAssignmentRecord]
    ) -> ActionShortcutStoreWriteResult {
        replaceAll(assignments, allowsRecovery: true, reportsCommittedChange: true)
    }

    func reportCommittedAssignmentsChange() {
        preferencesBackupChangeReporter?.didPersist(.actionShortcutAssignments)
    }

    private func replaceAll(
        _ assignments: [ActionShortcutAssignmentRecord],
        allowsRecovery: Bool,
        reportsCommittedChange: Bool
    ) -> ActionShortcutStoreWriteResult {
        let previousAssignments = self.assignments()
        let previousPayloadWasValid = loadError == nil
        guard allowsRecovery || previousPayloadWasValid else {
            return .rejected(rollbackSucceeded: true)
        }
        guard assignments.count <= Self.maximumAssignmentCount,
              Set(assignments.map(\.id)).count == assignments.count,
              let data = encodedPayload(assignments) else {
            return .rejected(rollbackSucceeded: true)
        }
        if previousPayloadWasValid, previousAssignments == assignments {
            return .committed
        }
        let previousValue = defaults.object(forKey: DefaultsKey.payload)
        defaults.set(data, forKey: DefaultsKey.payload)
        guard defaults.data(forKey: DefaultsKey.payload) == data else {
            return .rejected(
                rollbackSucceeded: restore(previousValue, forKey: DefaultsKey.payload)
            )
        }
        loadError = nil
        if reportsCommittedChange {
            reportCommittedAssignmentsChange()
        }
        return .committed
    }

    func assignment(for reference: ActionReference) -> ActionShortcutAssignmentRecord? {
        assignments().first { $0.reference == reference }
    }

    @discardableResult
    func migrateLegacyAppAssignments(
        _ candidates: [(reference: ActionReference, binding: ShortcutBinding)],
        didPersist: () -> Void
    ) -> ActionShortcutLegacyMigrationResult {
        guard !defaults.bool(forKey: DefaultsKey.legacyAppMigration) else {
            return .alreadyMigrated
        }

        var records = assignments()
        guard loadError == nil else { return .rejected(rollbackSucceeded: true) }
        for candidate in candidates where !records.contains(where: {
            $0.reference == candidate.reference
        }) {
            records.append(
                ActionShortcutAssignmentRecord(
                    reference: candidate.reference,
                    binding: candidate.binding
                )
            )
        }
        return migrate(
            records: records,
            markerKey: DefaultsKey.legacyAppMigration,
            didPersist: didPersist
        )
    }

    @discardableResult
    func migrateLegacyPluginAssignments(
        pluginID: String,
        assignments: [LegacyActionShortcutAssignment],
        didPersist: () -> Void
    ) -> ActionShortcutLegacyMigrationResult {
        let migrationKey = DefaultsKey.legacyPluginMigrationPrefix + pluginID
        guard !defaults.bool(forKey: migrationKey) else {
            return .alreadyMigrated
        }

        var records = self.assignments()
        guard loadError == nil else { return .rejected(rollbackSucceeded: true) }
        for assignment in assignments where !records.contains(where: {
            $0.reference == assignment.reference
        }) {
            records.append(
                ActionShortcutAssignmentRecord(
                    reference: assignment.reference,
                    binding: assignment.binding
                )
            )
        }
        return migrate(records: records, markerKey: migrationKey, didPersist: didPersist)
    }

    private func migrate(
        records: [ActionShortcutAssignmentRecord],
        markerKey: String,
        didPersist: () -> Void
    ) -> ActionShortcutLegacyMigrationResult {
        let previousAssignments = assignments()
        guard records.count <= Self.maximumAssignmentCount,
              Set(records.map(\.id)).count == records.count,
              let candidateData = encodedPayload(records) else {
            return .rejected(rollbackSucceeded: true)
        }
        let previousValue = defaults.object(forKey: DefaultsKey.payload)
        let previousMarker = defaults.object(forKey: markerKey)

        defaults.set(candidateData, forKey: DefaultsKey.payload)
        guard defaults.data(forKey: DefaultsKey.payload) == candidateData else {
            let payloadRestored = restore(previousValue, forKey: DefaultsKey.payload)
            let markerRestored = restore(previousMarker, forKey: markerKey)
            return .rejected(rollbackSucceeded: payloadRestored && markerRestored)
        }

        defaults.set(true, forKey: markerKey)
        guard defaults.bool(forKey: markerKey),
              defaults.data(forKey: DefaultsKey.payload) == candidateData else {
            let payloadRestored = restore(previousValue, forKey: DefaultsKey.payload)
            let markerRestored = restore(previousMarker, forKey: markerKey)
            return .rejected(rollbackSucceeded: payloadRestored && markerRestored)
        }

        loadError = nil
        didPersist()
        if previousAssignments != records {
            preferencesBackupChangeReporter?.didPersist(.actionShortcutAssignments)
        }
        return .migrated
    }

    private func encodedPayload(
        _ assignments: [ActionShortcutAssignmentRecord]
    ) -> Data? {
        try? encoder.encode(
            Payload(version: Self.currentVersion, assignments: assignments)
        )
    }

    private func restore(_ value: Any?, forKey key: String) -> Bool {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        return valuesMatch(defaults.object(forKey: key), value)
    }

    private func valuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs as NSObject, rhs as NSObject):
            lhs.isEqual(rhs)
        default:
            false
        }
    }
}
