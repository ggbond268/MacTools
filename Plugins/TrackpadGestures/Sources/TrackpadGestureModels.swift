import Foundation
import MacToolsPluginKit

extension TrackpadGesture {
    var settingsOrder: Int {
        Self.configurableCases.firstIndex(of: self) ?? Self.configurableCases.count
    }

    /// The contact count that can also satisfy the standalone Middle Click plugin's
    /// short-tap recognizer. Long touches are intentionally excluded because their
    /// minimum duration is longer than Middle Click's maximum tap duration.
    var middleClickOverlapFingerCount: Int? {
        let count = fingerTapCount
            ?? doubleFingerTapCount
            ?? physicalClickFingerCount
            ?? tipTapConfiguration.map { $0.fixedFingerCount + 1 }
        guard let count, (3...5).contains(count) else { return nil }
        return count
    }

}

enum TrackpadGestureMappingSort: String, CaseIterable, Sendable {
    case gesture
    case enabledFirst
    case actionName
    case addedOrder
}

enum TrackpadGestureMappingStatusFilter: String, CaseIterable, Sendable {
    case all
    case enabled
    case disabled
}

enum TrackpadGestureMappingActionFilter: String, CaseIterable, Sendable {
    case all
    case macToolsAction
    case keyboardShortcut
    case singleKey
    case middleClick
}

enum TrackpadGestureAction: Codable, Equatable, Sendable {
    case action(ActionReference)
    case keyboardShortcut(ShortcutBinding)
    case keyTap(KeyboardKeyTap)
    case middleClick

    private enum CodingKeys: String, CodingKey {
        case kind
        case reference
        case shortcut
        case keyTap
    }

    private enum Kind: String, Codable {
        case action
        case keyboardShortcut
        case keyTap
        case middleClick
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .action:
            self = .action(try container.decode(ActionReference.self, forKey: .reference))
        case .keyboardShortcut:
            self = .keyboardShortcut(try container.decode(ShortcutBinding.self, forKey: .shortcut))
        case .keyTap:
            self = .keyTap(try container.decode(KeyboardKeyTap.self, forKey: .keyTap))
        case .middleClick:
            self = .middleClick
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .action(reference):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case let .keyboardShortcut(shortcut):
            try container.encode(Kind.keyboardShortcut, forKey: .kind)
            try container.encode(shortcut, forKey: .shortcut)
        case let .keyTap(keyTap):
            try container.encode(Kind.keyTap, forKey: .kind)
            try container.encode(keyTap, forKey: .keyTap)
        case .middleClick:
            try container.encode(Kind.middleClick, forKey: .kind)
        }
    }
}

struct TrackpadGestureMapping: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var gesture: TrackpadGesture
    var action: TrackpadGestureAction
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        gesture: TrackpadGesture,
        action: TrackpadGestureAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.gesture = gesture
        self.action = action
        self.isEnabled = isEnabled
    }
}

struct LegacyMiddleClickPreferences: Codable, Equatable, Sendable {
    let isEnabled: Bool
    let fingerCount: Int

    private enum Key {
        static let enabled = "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        static let fingerCount = "plugin.mouse-enhancer.mouse-enhancer.middle-click.finger-count"
    }

    static func load(from defaults: UserDefaults = .standard) -> LegacyMiddleClickPreferences? {
        guard defaults.object(forKey: Key.enabled) != nil else {
            return nil
        }

        let storedCount = defaults.object(forKey: Key.fingerCount) == nil
            ? 3
            : defaults.integer(forKey: Key.fingerCount)
        return LegacyMiddleClickPreferences(
            isEnabled: defaults.bool(forKey: Key.enabled),
            fingerCount: [3, 4, 5].contains(storedCount) ? storedCount : 3
        )
    }
}

@MainActor
final class TrackpadGestureStore: ObservableObject {
    private struct PortableBackup: Codable {
        let formatVersion: Int
        let mappings: [TrackpadGestureMapping]
        let ignoresGesturesWhileTyping: Bool
        let typingGracePeriod: TimeInterval
    }

    private struct PortableRestoreTransaction: Codable {
        let mappings: Data?
        let ignoresGesturesWhileTyping: Bool?
        let typingGracePeriod: TimeInterval?
    }

    private static let portableBackupFormatVersion = 1
    private static let maximumPortableBackupByteCount = 256 * 1_024
    private struct LegacyMiddleClickMigrationRecord: Codable {
        let preferences: LegacyMiddleClickPreferences
        let mappingID: UUID?
    }

    private enum Key {
        static let mappings = "mappings"
        static let middleClickMigrationRecord = "migration.mouse-enhancer-middle-click.v2"
        static let ignoreWhileTyping = "ignore-while-typing"
        static let typingGracePeriod = "typing-grace-period"
        static let mappingSort = "settings.mapping-sort"
        static let mappingStatusFilter = "settings.mapping-status-filter"
        static let mappingActionFilter = "settings.mapping-action-filter"
        static let portableRestoreTransaction = "portable-restore-transaction.v1"
    }

    @Published private(set) var mappings: [TrackpadGestureMapping]
    @Published private(set) var isTesting = false
    @Published private(set) var lastTestGesture: TrackpadGesture?
    @Published private(set) var ignoresGesturesWhileTyping: Bool
    @Published private(set) var typingGracePeriod: TimeInterval
    @Published private(set) var mappingSort: TrackpadGestureMappingSort
    @Published private(set) var mappingStatusFilter: TrackpadGestureMappingStatusFilter
    @Published private(set) var mappingActionFilter: TrackpadGestureMappingActionFilter
    private(set) var didPersistPortablePreferencesDuringInitialization = false

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()

    init(
        storage: any PluginStorage,
        legacyMiddleClick: LegacyMiddleClickPreferences? = LegacyMiddleClickPreferences.load()
    ) {
        self.storage = storage
        let initialMappingsData = storage.data(forKey: Key.mappings)
        let initialIgnoresGesturesWhileTyping = Self.storedBool(
            forKey: Key.ignoreWhileTyping,
            storage: storage
        )
        let initialTypingGracePeriod = Self.storedDouble(
            forKey: Key.typingGracePeriod,
            storage: storage
        )
        _ = Self.recoverInterruptedPortableRestore(storage: storage)
        let decoded = storage.data(forKey: Key.mappings)
            .flatMap { try? JSONDecoder().decode([TrackpadGestureMapping].self, from: $0) }
            ?? []
        self.mappings = Self.normalized(decoded)
        self.ignoresGesturesWhileTyping = storage.object(forKey: Key.ignoreWhileTyping)
            .map { ($0 as? NSNumber)?.boolValue ?? true }
            ?? true
        let storedGracePeriod = (storage.object(forKey: Key.typingGracePeriod) as? NSNumber)?.doubleValue
            ?? TrackpadTypingSuppressionGate.defaultGracePeriod
        self.typingGracePeriod = TrackpadTypingSuppressionGate.clamped(storedGracePeriod)
        self.mappingSort = storage.string(forKey: Key.mappingSort)
            .flatMap(TrackpadGestureMappingSort.init(rawValue:))
            ?? .gesture
        self.mappingStatusFilter = storage.string(forKey: Key.mappingStatusFilter)
            .flatMap(TrackpadGestureMappingStatusFilter.init(rawValue:))
            ?? .all
        self.mappingActionFilter = storage.string(forKey: Key.mappingActionFilter)
            .flatMap(TrackpadGestureMappingActionFilter.init(rawValue:))
            ?? .all
        migrateLegacyMiddleClickIfNeeded(legacyMiddleClick)
        didPersistPortablePreferencesDuringInitialization =
            storage.data(forKey: Key.mappings) != initialMappingsData
            || Self.storedBool(forKey: Key.ignoreWhileTyping, storage: storage)
                != initialIgnoresGesturesWhileTyping
            || Self.storedDouble(forKey: Key.typingGracePeriod, storage: storage)
                != initialTypingGracePeriod
    }

    var enabledGestures: Set<TrackpadGesture> {
        Set(mappings.lazy.filter(\.isEnabled).map(\.gesture))
    }

    func mapping(for gesture: TrackpadGesture) -> TrackpadGestureMapping? {
        mappings.first { $0.gesture == gesture }
    }

    func conflictingMapping(
        for gesture: TrackpadGesture,
        excludingID: UUID? = nil
    ) -> TrackpadGestureMapping? {
        mappings.first { $0.id != excludingID && $0.gesture == gesture }
    }

    func availableGestures(excludingID: UUID? = nil) -> [TrackpadGesture] {
        TrackpadGesture.configurableCases.filter {
            conflictingMapping(for: $0, excludingID: excludingID) == nil
        }
    }

    func mappings(
        using shortcut: ShortcutBinding,
        excludingID: UUID? = nil
    ) -> [TrackpadGestureMapping] {
        mappings.filter { mapping in
            guard mapping.id != excludingID,
                  case let .keyboardShortcut(existingShortcut) = mapping.action
            else {
                return false
            }
            return existingShortcut == shortcut
        }
    }

    @discardableResult
    func save(_ mapping: TrackpadGestureMapping) -> Bool {
        guard conflictingMapping(for: mapping.gesture, excludingID: mapping.id) == nil else {
            return false
        }
        guard Self.isValid(mapping) else {
            return false
        }

        var candidate = mappings
        if let index = candidate.firstIndex(where: { $0.id == mapping.id }) {
            candidate[index] = mapping
        } else {
            candidate.append(mapping)
        }
        guard persist(candidate) else { return false }
        mappings = candidate
        return true
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, id: UUID) -> Bool {
        guard let index = mappings.firstIndex(where: { $0.id == id }),
              mappings[index].isEnabled != isEnabled
        else {
            return false
        }
        var candidate = mappings
        candidate[index].isEnabled = isEnabled
        guard persist(candidate) else { return false }
        mappings = candidate
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let candidate = mappings.filter { $0.id != id }
        guard candidate.count != mappings.count,
              persist(candidate) else { return false }
        mappings = candidate
        return true
    }

    func setTesting(_ isTesting: Bool) {
        self.isTesting = isTesting
        if !isTesting {
            lastTestGesture = nil
        }
    }

    func recordTestGesture(_ gesture: TrackpadGesture) {
        lastTestGesture = gesture
    }

    @discardableResult
    func setIgnoresGesturesWhileTyping(_ isEnabled: Bool) -> Bool {
        guard ignoresGesturesWhileTyping != isEnabled else { return false }
        let previousRawValue = storage.object(forKey: Key.ignoreWhileTyping)
        storage.set(isEnabled, forKey: Key.ignoreWhileTyping)
        guard Self.storedBool(forKey: Key.ignoreWhileTyping, storage: storage) == isEnabled else {
            Self.setOptional(previousRawValue, forKey: Key.ignoreWhileTyping, storage: storage)
            return false
        }
        ignoresGesturesWhileTyping = isEnabled
        return true
    }

    @discardableResult
    func setTypingGracePeriod(_ gracePeriod: TimeInterval) -> Bool {
        let clamped = TrackpadTypingSuppressionGate.clamped(gracePeriod)
        guard typingGracePeriod != clamped else { return false }
        let previousRawValue = storage.object(forKey: Key.typingGracePeriod)
        storage.set(clamped, forKey: Key.typingGracePeriod)
        guard Self.storedDouble(forKey: Key.typingGracePeriod, storage: storage) == clamped else {
            Self.setOptional(previousRawValue, forKey: Key.typingGracePeriod, storage: storage)
            return false
        }
        typingGracePeriod = clamped
        return true
    }

    func setMappingSort(_ sort: TrackpadGestureMappingSort) {
        guard mappingSort != sort else { return }
        mappingSort = sort
        storage.set(sort.rawValue, forKey: Key.mappingSort)
    }

    func setMappingStatusFilter(_ filter: TrackpadGestureMappingStatusFilter) {
        guard mappingStatusFilter != filter else { return }
        mappingStatusFilter = filter
        storage.set(filter.rawValue, forKey: Key.mappingStatusFilter)
    }

    func setMappingActionFilter(_ filter: TrackpadGestureMappingActionFilter) {
        guard mappingActionFilter != filter else { return }
        mappingActionFilter = filter
        storage.set(filter.rawValue, forKey: Key.mappingActionFilter)
    }

    func resetMappingViewPreferences() {
        setMappingSort(.gesture)
        setMappingStatusFilter(.all)
        setMappingActionFilter(.all)
    }

    @discardableResult
    func migrateActions(using context: TrackpadActionHostContext) -> Bool {
        var updated = mappings
        var changed = false
        for index in updated.indices {
            guard case let .action(reference) = updated[index].action,
                  let migrated = context.migrate(reference),
                  migrated != reference else {
                continue
            }
            updated[index].action = .action(migrated)
            changed = true
        }
        guard changed else { return false }
        let candidate = Self.normalized(updated)
        guard persist(candidate) else { return false }
        mappings = candidate
        return true
    }

    func portableBackup(using context: TrackpadActionHostContext? = nil) -> Data? {
        let backup = PortableBackup(
            formatVersion: Self.portableBackupFormatVersion,
            mappings: mappings.filter { mapping in
                guard case let .action(reference) = mapping.action else { return true }
                return context?.canExport(reference) ?? true
            },
            ignoresGesturesWhileTyping: ignoresGesturesWhileTyping,
            typingGracePeriod: typingGracePeriod
        )
        guard let data = try? encoder.encode(backup),
              data.count <= Self.maximumPortableBackupByteCount else {
            return nil
        }
        return data
    }

    func actionReferences(inPortableBackup data: Data) -> [ActionReference]? {
        guard data.count <= Self.maximumPortableBackupByteCount,
              let backup = try? JSONDecoder().decode(PortableBackup.self, from: data),
              backup.formatVersion == Self.portableBackupFormatVersion,
              backup.mappings == Self.normalized(backup.mappings) else {
            return nil
        }
        return backup.mappings.compactMap { mapping in
            guard case let .action(reference) = mapping.action else { return nil }
            return reference
        }
    }

    @discardableResult
    func restorePortableBackup(
        _ data: Data,
        using context: TrackpadActionHostContext? = nil
    ) -> Bool {
        guard data.count <= Self.maximumPortableBackupByteCount,
              let backup = try? JSONDecoder().decode(PortableBackup.self, from: data),
              backup.formatVersion == Self.portableBackupFormatVersion,
              backup.mappings == Self.normalized(backup.mappings),
              backup.mappings.allSatisfy({ mapping in
                  guard case let .action(reference) = mapping.action else { return true }
                  return context?.canRestore(reference) ?? true
              }) else {
            return false
        }
        guard let mappingData = try? encoder.encode(backup.mappings) else { return false }
        let gracePeriod = TrackpadTypingSuppressionGate.clamped(backup.typingGracePeriod)
        if backup.mappings == mappings,
           backup.ignoresGesturesWhileTyping == ignoresGesturesWhileTyping,
           gracePeriod == typingGracePeriod {
            return true
        }
        guard recoverInterruptedPortableRestore(),
              beginPortableRestoreTransaction(),
              writePortableValues(
                  mappings: mappingData,
                  ignoresGesturesWhileTyping: backup.ignoresGesturesWhileTyping,
                  typingGracePeriod: gracePeriod
              ),
              finishPortableRestoreTransaction() else {
            rollbackPortableRestoreTransaction()
            return false
        }
        mappings = backup.mappings
        ignoresGesturesWhileTyping = backup.ignoresGesturesWhileTyping
        typingGracePeriod = gracePeriod
        return true
    }

    private func beginPortableRestoreTransaction() -> Bool {
        guard Self.hasExpectedData(forKey: Key.mappings, storage: storage),
              Self.hasExpectedBool(forKey: Key.ignoreWhileTyping, storage: storage),
              Self.hasExpectedDouble(forKey: Key.typingGracePeriod, storage: storage) else {
            return false
        }
        let transaction = PortableRestoreTransaction(
            mappings: storage.data(forKey: Key.mappings),
            ignoresGesturesWhileTyping: Self.storedBool(
                forKey: Key.ignoreWhileTyping,
                storage: storage
            ),
            typingGracePeriod: Self.storedDouble(
                forKey: Key.typingGracePeriod,
                storage: storage
            )
        )
        guard let data = try? encoder.encode(transaction) else { return false }
        storage.set(data, forKey: Key.portableRestoreTransaction)
        return storage.data(forKey: Key.portableRestoreTransaction) == data
    }

    private func recoverInterruptedPortableRestore() -> Bool {
        Self.recoverInterruptedPortableRestore(storage: storage)
    }

    private static func recoverInterruptedPortableRestore(storage: any PluginStorage) -> Bool {
        guard let rawTransaction = storage.object(forKey: Key.portableRestoreTransaction) else {
            return true
        }
        guard let transactionData = rawTransaction as? Data else { return false }
        guard let transaction = try? JSONDecoder().decode(
            PortableRestoreTransaction.self,
            from: transactionData
        ), writePortableValues(transaction, storage: storage) else {
            return false
        }
        storage.removeObject(forKey: Key.portableRestoreTransaction)
        return storage.object(forKey: Key.portableRestoreTransaction) == nil
    }

    @discardableResult
    private func rollbackPortableRestoreTransaction() -> Bool {
        recoverInterruptedPortableRestore()
    }

    private func finishPortableRestoreTransaction() -> Bool {
        storage.removeObject(forKey: Key.portableRestoreTransaction)
        return storage.object(forKey: Key.portableRestoreTransaction) == nil
    }

    private func writePortableValues(
        mappings: Data?,
        ignoresGesturesWhileTyping: Bool?,
        typingGracePeriod: TimeInterval?
    ) -> Bool {
        Self.writePortableValues(
            PortableRestoreTransaction(
                mappings: mappings,
                ignoresGesturesWhileTyping: ignoresGesturesWhileTyping,
                typingGracePeriod: typingGracePeriod
            ),
            storage: storage
        )
    }

    private static func writePortableValues(
        _ values: PortableRestoreTransaction,
        storage: any PluginStorage
    ) -> Bool {
        setOptional(values.mappings, forKey: Key.mappings, storage: storage)
        setOptional(
            values.ignoresGesturesWhileTyping,
            forKey: Key.ignoreWhileTyping,
            storage: storage
        )
        setOptional(
            values.typingGracePeriod,
            forKey: Key.typingGracePeriod,
            storage: storage
        )
        return storage.data(forKey: Key.mappings) == values.mappings
            && storedBool(forKey: Key.ignoreWhileTyping, storage: storage)
                == values.ignoresGesturesWhileTyping
            && storedDouble(forKey: Key.typingGracePeriod, storage: storage)
                == values.typingGracePeriod
    }

    private static func setOptional(_ value: Any?, forKey key: String, storage: any PluginStorage) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private static func storedBool(forKey key: String, storage: any PluginStorage) -> Bool? {
        if let value = storage.object(forKey: key) as? Bool {
            return value
        }
        return (storage.object(forKey: key) as? NSNumber)?.boolValue
    }

    private static func storedDouble(forKey key: String, storage: any PluginStorage) -> Double? {
        if let value = storage.object(forKey: key) as? Double {
            return value
        }
        return (storage.object(forKey: key) as? NSNumber)?.doubleValue
    }

    private static func hasExpectedData(forKey key: String, storage: any PluginStorage) -> Bool {
        guard let rawValue = storage.object(forKey: key) else { return true }
        return rawValue is Data
    }

    private static func hasExpectedBool(forKey key: String, storage: any PluginStorage) -> Bool {
        guard storage.object(forKey: key) != nil else { return true }
        return storedBool(forKey: key, storage: storage) != nil
    }

    private static func hasExpectedDouble(forKey key: String, storage: any PluginStorage) -> Bool {
        guard storage.object(forKey: key) != nil else { return true }
        return storedDouble(forKey: key, storage: storage) != nil
    }

    private func migrateLegacyMiddleClickIfNeeded(_ legacy: LegacyMiddleClickPreferences?) {
        guard let legacy else {
            return
        }

        let previousRecord = storage.data(forKey: Key.middleClickMigrationRecord)
            .flatMap { try? JSONDecoder().decode(LegacyMiddleClickMigrationRecord.self, from: $0) }
        guard previousRecord?.preferences != legacy else {
            return
        }

        let mappingID = reconcileLegacyMiddleClick(legacy, previousRecord: previousRecord)
        let record = LegacyMiddleClickMigrationRecord(
            preferences: legacy,
            mappingID: mappingID
        )
        if let data = try? encoder.encode(record) {
            // Mouse Enhancer keys remain untouched so a temporary host downgrade can restore the
            // legacy owner. This record lets the next upgrade detect values changed while old.
            storage.set(data, forKey: Key.middleClickMigrationRecord)
        }
    }

    private func reconcileLegacyMiddleClick(
        _ legacy: LegacyMiddleClickPreferences,
        previousRecord: LegacyMiddleClickMigrationRecord?
    ) -> UUID? {
        let desiredGesture = TrackpadGesture.fingerTap(count: legacy.fingerCount)

        if let previousRecord,
           let mappingID = previousRecord.mappingID,
           let index = mappings.firstIndex(where: { $0.id == mappingID }),
           mappings[index] == TrackpadGestureMapping(
               id: mappingID,
               gesture: .fingerTap(count: previousRecord.preferences.fingerCount),
               action: .middleClick,
               isEnabled: previousRecord.preferences.isEnabled
            ) {
            if conflictingMapping(for: desiredGesture, excludingID: mappingID) == nil {
                var candidate = mappings
                candidate[index].gesture = desiredGesture
                candidate[index].isEnabled = legacy.isEnabled
                guard persist(candidate) else { return nil }
                mappings = candidate
                return mappingID
            }

            // A newer explicit mapping wins the desired gesture. Remove only the unchanged
            // migration-owned mapping so the superseded legacy gesture does not remain active.
            var candidate = mappings
            candidate.remove(at: index)
            guard persist(candidate) else { return nil }
            mappings = candidate
            return nil
        }

        // Existing mappings may predate the versioned migration record or may have been edited by
        // the user. Never claim or overwrite them without positive ownership evidence.
        guard conflictingMapping(for: desiredGesture) == nil else {
            return nil
        }

        let mapping = TrackpadGestureMapping(
            gesture: desiredGesture,
            action: .middleClick,
            isEnabled: legacy.isEnabled
        )
        let candidate = mappings + [mapping]
        guard persist(candidate) else { return nil }
        mappings = candidate
        return mapping.id
    }

    private func persist(_ candidate: [TrackpadGestureMapping]) -> Bool {
        guard let data = try? encoder.encode(candidate) else { return false }
        let previousRawValue = storage.object(forKey: Key.mappings)
        storage.set(data, forKey: Key.mappings)
        guard storage.data(forKey: Key.mappings) == data else {
            Self.setOptional(previousRawValue, forKey: Key.mappings, storage: storage)
            return false
        }
        return true
    }

    private static func normalized(_ candidates: [TrackpadGestureMapping]) -> [TrackpadGestureMapping] {
        var seenGestures = Set<TrackpadGesture>()
        var seenIDs = Set<UUID>()
        return candidates.filter { mapping in
            guard isValid(mapping),
                  seenIDs.insert(mapping.id).inserted,
                  seenGestures.insert(mapping.gesture).inserted
            else {
                return false
            }
            return true
        }
    }

    private static func isValid(_ mapping: TrackpadGestureMapping) -> Bool {
        return switch mapping.action {
        case .action:
            true
        case let .keyboardShortcut(binding):
            binding.isValid
        case let .keyTap(keyTap):
            keyTap.isSupported
        case .middleClick:
            true
        }
    }
}
