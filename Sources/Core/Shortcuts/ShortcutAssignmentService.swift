import Carbon
import Foundation
import MacToolsPluginKit

enum ActionShortcutAssignmentError: Error, Equatable {
    case unavailableAction
    case invalidBinding(ShortcutValidationError)
    case conflict(ownerDescription: String)
    case persistenceFailed
    case persistenceRollbackFailed
    case recoveryRequired

    var localizedDescription: String {
        switch self {
        case .unavailableAction:
            return FeatureL10n.string("操作不可用。")
        case let .invalidBinding(error):
            return error.localizedDescription
        case let .conflict(ownerDescription):
            return ShortcutValidationError.duplicate(
                ownerDescription: ownerDescription
            ).localizedDescription
        case .persistenceFailed:
            return FeatureL10n.string("无法保存快捷键。")
        case .persistenceRollbackFailed:
            return FeatureL10n.string("无法保存快捷键，且恢复先前快捷键失败。")
        case .recoveryRequired:
            return FeatureL10n.string("快捷键数据无法读取；请先导入备份恢复。")
        }
    }
}

enum ActionShortcutMutationResult: Equatable {
    case success
    case failure(ActionShortcutAssignmentError)
}

enum ActionShortcutRegistrationState: Equatable {
    case registered
    case unavailable(reason: String?)
    case conflict(ownerDescription: String)
    case registrationFailed(code: OSStatus)
    case invalidBinding
}

enum ActionShortcutCatalogStatus: Equatable {
    case assigned
    case unassigned
    case conflicted(String)
    case unavailable(String?)
}

struct ActionShortcutCatalogItem: Identifiable, Equatable {
    struct ID: Hashable {
        let reference: ActionReference
        let assignmentID: UUID?
    }

    let reference: ActionReference
    let assignmentID: UUID?
    let title: String
    let ownerTitle: String
    let description: String
    let permissionSummary: String?
    let systemImage: String
    let bindingText: String
    let status: ActionShortcutCatalogStatus
    let canAssign: Bool

    var id: ID { ID(reference: reference, assignmentID: assignmentID) }
}

struct ActionShortcutSettingsItem: Identifiable, Equatable {
    let assignment: ActionShortcutAssignmentRecord
    let title: String
    let subtitle: String?
    let state: ActionShortcutRegistrationState

    var id: UUID {
        assignment.id
    }

    var bindingText: String {
        ShortcutFormatter.displayString(for: assignment.binding)
    }
}

@MainActor
final class ShortcutAssignmentService {
    private static let shortcutIDPrefix = "action-shortcut."

    private let registry: ActionRegistry
    private let store: ActionShortcutAssignmentStore
    private let shortcutManager: GlobalShortcutManager

    private var reservedRegistrations: [GlobalShortcutManager.Registration] = []
    private var reservedOwnerDescriptions: [String: String] = [:]
    private var referencesByShortcutID: [String: ActionReference] = [:]

    private(set) var settingsItems: [ActionShortcutSettingsItem] = []
    private(set) var revision: UInt64 = 0

    init(
        registry: ActionRegistry,
        store: ActionShortcutAssignmentStore,
        shortcutManager: GlobalShortcutManager
    ) {
        self.registry = registry
        self.store = store
        self.shortcutManager = shortcutManager
    }

    var assignments: [ActionShortcutAssignmentRecord] {
        store.assignments()
    }

    func assignment(for reference: ActionReference) -> ActionShortcutAssignmentRecord? {
        store.assignment(for: reference)
    }

    func settingsItem(for reference: ActionReference) -> ActionShortcutSettingsItem? {
        settingsItems.first { $0.assignment.reference == reference }
    }

    func settingsItems(for reference: ActionReference) -> [ActionShortcutSettingsItem] {
        settingsItems.filter { $0.assignment.reference == reference }
    }

    func reference(forShortcutID shortcutID: String) -> ActionReference? {
        referencesByShortcutID[shortcutID]
    }

    @discardableResult
    func assign(
        _ binding: ShortcutBinding,
        to reference: ActionReference,
        assignmentID: UUID? = nil,
        replacingConflictingActionAssignments: Bool = false
    ) -> ActionShortcutMutationResult {
        guard binding.hasRequiredModifiers else {
            return .failure(.invalidBinding(.missingModifier))
        }
        guard !ShortcutKeyCode.isModifier(binding.keyCode) else {
            return .failure(.invalidBinding(.modifierOnly))
        }
        if let error = MacToolsReservedShortcutBindings.validationError(for: binding) {
            return .failure(.invalidBinding(error))
        }

        guard case let .success(action) = registry.registeredAction(for: reference),
              action.catalogEntry != nil,
              action.definition.capabilities.contains(.foregroundInteractive) else {
            return .failure(.unavailableAction)
        }

        if let reserved = reservedRegistrations.first(where: { $0.binding == binding }) {
            return .failure(
                .conflict(
                    ownerDescription: reservedOwnerDescriptions[reserved.shortcutID]
                        ?? reserved.shortcutID
                )
            )
        }

        var records = store.assignments()
        guard store.loadError == nil else {
            return .failure(.recoveryRequired)
        }
        let targetID = assignmentID
            ?? records.first(where: { $0.reference == reference })?.id
        if let assignmentID,
           !records.contains(where: { $0.id == assignmentID && $0.reference == reference }) {
            return .failure(.unavailableAction)
        }
        let conflictingRecords = records.filter {
            $0.id != targetID && $0.binding == binding
        }
        if let conflict = conflictingRecords.first,
           !replacingConflictingActionAssignments {
            return .failure(
                .conflict(ownerDescription: title(for: conflict.reference))
            )
        }
        if replacingConflictingActionAssignments {
            let conflictingIDs = Set(conflictingRecords.map(\.id))
            records.removeAll { conflictingIDs.contains($0.id) }
        }

        if let targetID,
           let index = records.firstIndex(where: { $0.id == targetID }) {
            records[index] = ActionShortcutAssignmentRecord(
                id: records[index].id,
                reference: reference,
                binding: binding
            )
        } else {
            records.append(
                ActionShortcutAssignmentRecord(reference: reference, binding: binding)
            )
        }

        switch store.replaceAll(records) {
        case .committed:
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .success
        case .rejected(rollbackSucceeded: true):
            return .failure(.persistenceFailed)
        case .rejected(rollbackSucceeded: false):
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .failure(.persistenceRollbackFailed)
        }
    }

    /// Previews the assignments managed by a plugin shortcut preset without mutating them.
    func replacementPreview(
        providerID: String,
        managedActionIDs: Set<String>,
        bindingsByActionID: [String: ShortcutBinding]
    ) -> PluginActionShortcutPresetPreview {
        guard !providerID.isEmpty,
              !managedActionIDs.isEmpty,
              Set(bindingsByActionID.keys).isSubset(of: managedActionIDs)
        else {
            return PluginActionShortcutPresetPreview(
                items: [],
                errorMessage: ActionShortcutAssignmentError.unavailableAction.localizedDescription
            )
        }

        let records = store.assignments()
        guard store.loadError == nil else {
            return PluginActionShortcutPresetPreview(
                items: [],
                errorMessage: ActionShortcutAssignmentError.recoveryRequired.localizedDescription
            )
        }
        let retainedRecords = records.filter { record in
            record.reference.key.providerID != providerID
                || !managedActionIDs.contains(record.reference.key.actionID)
        }

        var items: [PluginActionShortcutPresetPreviewItem] = []
        var proposedBindingOwners: [ShortcutBinding: ActionReference] = [:]
        items.reserveCapacity(managedActionIDs.count)
        for actionID in managedActionIDs.sorted() {
            let reference = ActionReference(
                key: ActionKey(providerID: providerID, actionID: actionID)
            )
            let proposedBinding = bindingsByActionID[actionID]
            let currentBindings = records.compactMap { record in
                record.reference.key == reference.key ? record.binding : nil
            }
            let representativeCurrentBinding = currentBindings.first(where: {
                $0 != proposedBinding
            }) ?? currentBindings.first
            guard case let .success(action) = registry.registeredAction(for: reference),
                  action.catalogEntry != nil,
                  action.definition.capabilities.contains(.foregroundInteractive)
            else {
                if proposedBinding == nil {
                    items.append(PluginActionShortcutPresetPreviewItem(
                        actionID: actionID,
                        currentBinding: representativeCurrentBinding,
                        proposedBinding: nil
                    ))
                    continue
                }
                return PluginActionShortcutPresetPreview(
                    items: items,
                    errorMessage: ActionShortcutAssignmentError.unavailableAction.localizedDescription
                )
            }

            let conflictOwnerDescription: String?
            if let proposedBinding, !proposedBinding.hasRequiredModifiers {
                return PluginActionShortcutPresetPreview(
                    items: items,
                    errorMessage: ActionShortcutAssignmentError
                        .invalidBinding(.missingModifier).localizedDescription
                )
            } else if let proposedBinding, ShortcutKeyCode.isModifier(proposedBinding.keyCode) {
                return PluginActionShortcutPresetPreview(
                    items: items,
                    errorMessage: ActionShortcutAssignmentError
                        .invalidBinding(.modifierOnly).localizedDescription
                )
            } else if let proposedBinding,
                      let error = MacToolsReservedShortcutBindings.validationError(
                          for: proposedBinding
                      ) {
                return PluginActionShortcutPresetPreview(
                    items: items,
                    errorMessage: ActionShortcutAssignmentError
                        .invalidBinding(error).localizedDescription
                )
            } else if let proposedBinding,
                      let existingOwner = proposedBindingOwners[proposedBinding] {
                conflictOwnerDescription = title(for: existingOwner)
            } else if let proposedBinding,
               let reserved = reservedRegistrations.first(where: {
                   $0.binding == proposedBinding
               }) {
                conflictOwnerDescription = reservedOwnerDescriptions[reserved.shortcutID]
                    ?? reserved.shortcutID
            } else if let proposedBinding,
                      let conflict = retainedRecords.first(where: {
                          $0.binding == proposedBinding
                      }) {
                conflictOwnerDescription = title(for: conflict.reference)
            } else {
                conflictOwnerDescription = nil
            }
            if let proposedBinding {
                proposedBindingOwners[proposedBinding] = reference
            }

            items.append(PluginActionShortcutPresetPreviewItem(
                actionID: actionID,
                currentBinding: representativeCurrentBinding,
                proposedBinding: proposedBinding,
                conflictOwnerDescription: conflictOwnerDescription
            ))
        }
        return PluginActionShortcutPresetPreview(items: items)
    }

    func currentBindings(
        providerID: String,
        managedActionIDs: Set<String>
    ) -> [String: [ShortcutBinding]] {
        guard store.loadError == nil else { return [:] }
        return store.assignments().reduce(into: [:]) { result, record in
            let key = record.reference.key
            guard key.providerID == providerID,
                  managedActionIDs.contains(key.actionID) else { return }
            result[key.actionID, default: []].append(record.binding)
        }
    }

    /// Atomically replaces the assignments managed by a plugin shortcut preset.
    @discardableResult
    func replaceAssignments(
        providerID: String,
        managedActionIDs: Set<String>,
        bindingsByActionID: [String: ShortcutBinding]
    ) -> ActionShortcutMutationResult {
        replaceAssignments(
            providerID: providerID,
            managedActionIDs: managedActionIDs,
            bindingsByActionID: bindingsByActionID,
            reportsCommittedChange: true
        )
    }

    private func replaceAssignments(
        providerID: String,
        managedActionIDs: Set<String>,
        bindingsByActionID: [String: ShortcutBinding],
        reportsCommittedChange: Bool
    ) -> ActionShortcutMutationResult {
        guard !providerID.isEmpty,
              !managedActionIDs.isEmpty,
              Set(bindingsByActionID.keys).isSubset(of: managedActionIDs)
        else {
            return .failure(.unavailableAction)
        }

        var requestedRecords: [ActionShortcutAssignmentRecord] = []
        var requestedBindingOwners: [ShortcutBinding: ActionReference] = [:]
        for actionID in bindingsByActionID.keys.sorted() {
            guard let binding = bindingsByActionID[actionID] else { continue }
            guard binding.hasRequiredModifiers else {
                return .failure(.invalidBinding(.missingModifier))
            }
            guard !ShortcutKeyCode.isModifier(binding.keyCode) else {
                return .failure(.invalidBinding(.modifierOnly))
            }
            if let error = MacToolsReservedShortcutBindings.validationError(for: binding) {
                return .failure(.invalidBinding(error))
            }

            let reference = ActionReference(
                key: ActionKey(providerID: providerID, actionID: actionID)
            )
            guard case let .success(action) = registry.registeredAction(for: reference),
                  action.catalogEntry != nil,
                  action.definition.capabilities.contains(.foregroundInteractive)
            else {
                return .failure(.unavailableAction)
            }
            if let existingOwner = requestedBindingOwners[binding] {
                return .failure(.conflict(ownerDescription: title(for: existingOwner)))
            }
            requestedBindingOwners[binding] = reference
            requestedRecords.append(
                ActionShortcutAssignmentRecord(reference: reference, binding: binding)
            )
        }

        var records = store.assignments()
        guard store.loadError == nil else {
            return .failure(.recoveryRequired)
        }
        records.removeAll { record in
            record.reference.key.providerID == providerID
                && managedActionIDs.contains(record.reference.key.actionID)
        }

        for requested in requestedRecords {
            if let reserved = reservedRegistrations.first(where: {
                $0.binding == requested.binding
            }) {
                return .failure(
                    .conflict(
                        ownerDescription: reservedOwnerDescriptions[reserved.shortcutID]
                            ?? reserved.shortcutID
                    )
                )
            }
            if let conflict = records.first(where: { $0.binding == requested.binding }) {
                return .failure(.conflict(ownerDescription: title(for: conflict.reference)))
            }
        }
        records.append(contentsOf: requestedRecords)

        switch store.replaceAll(records, reportsCommittedChange: reportsCommittedChange) {
        case .committed:
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .success
        case .rejected(rollbackSucceeded: true):
            return .failure(.persistenceFailed)
        case .rejected(rollbackSucceeded: false):
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .failure(.persistenceRollbackFailed)
        }
    }

    /// Replaces managed assignments and rolls their exact records back if the paired mutation fails.
    /// This keeps assignment IDs and converged records intact across a cross-store operation.
    func performReplacementTransaction(
        providerID: String,
        managedActionIDs: Set<String>,
        bindingsByActionID: [String: ShortcutBinding],
        mutation: () -> String?
    ) -> String? {
        let previousRecords = store.assignments()
        guard store.loadError == nil else {
            return ActionShortcutAssignmentError.recoveryRequired.localizedDescription
        }

        switch replaceAssignments(
            providerID: providerID,
            managedActionIDs: managedActionIDs,
            bindingsByActionID: bindingsByActionID,
            reportsCommittedChange: false
        ) {
        case let .failure(error):
            return error.localizedDescription
        case .success:
            break
        }

        let assignmentsChanged = store.assignments() != previousRecords
        guard let mutationError = mutation() else {
            if assignmentsChanged {
                store.reportCommittedAssignmentsChange()
            }
            return nil
        }
        switch store.replaceAll(previousRecords, reportsCommittedChange: false) {
        case .committed:
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return mutationError
        case .rejected:
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return mutationError + " "
                + ActionShortcutAssignmentError.persistenceRollbackFailed.localizedDescription
        }
    }

    /// Removes shortcut assignments for actions a loaded plugin has explicitly retired.
    @discardableResult
    func removeRetiredAssignments(
        providerID: String,
        actionIDs: Set<String>
    ) -> ActionShortcutMutationResult {
        guard !providerID.isEmpty, !actionIDs.isEmpty else {
            return .failure(.unavailableAction)
        }
        var records = store.assignments()
        guard store.loadError == nil else {
            return .failure(.recoveryRequired)
        }
        let previousCount = records.count
        records.removeAll { record in
            record.reference.key.providerID == providerID
                && actionIDs.contains(record.reference.key.actionID)
        }
        guard records.count != previousCount else { return .success }

        switch store.replaceAll(records) {
        case .committed:
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .success
        case .rejected(rollbackSucceeded: true):
            return .failure(.persistenceFailed)
        case .rejected(rollbackSucceeded: false):
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .failure(.persistenceRollbackFailed)
        }
    }

    @discardableResult
    func clear(
        _ reference: ActionReference,
        assignmentID: UUID? = nil
    ) -> ActionShortcutMutationResult {
        var records = store.assignments()
        guard store.loadError == nil else { return .failure(.recoveryRequired) }
        let originalCount = records.count
        records.removeAll { record in
            guard record.reference == reference else { return false }
            return assignmentID == nil || record.id == assignmentID
        }
        guard records.count != originalCount else {
            return .success
        }
        switch store.replaceAll(records) {
        case .committed:
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .success
        case .rejected(rollbackSucceeded: true):
            return .failure(.persistenceFailed)
        case .rejected(rollbackSucceeded: false):
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .failure(.persistenceRollbackFailed)
        }
    }

    @discardableResult
    func replaceAllForImport(
        _ records: [ActionShortcutAssignmentRecord],
        reservedRegistrations importedReservedRegistrations: [GlobalShortcutManager.Registration]? = nil,
        reservedOwnerDescriptions importedOwnerDescriptions: [String: String]? = nil
    ) -> ActionShortcutMutationResult {
        let records = migratedAssignments(records)
        let reservations = importedReservedRegistrations ?? reservedRegistrations
        let ownerDescriptions = importedOwnerDescriptions ?? reservedOwnerDescriptions
        if let error = importValidationError(
            records,
            reservedRegistrations: reservations,
            reservedOwnerDescriptions: ownerDescriptions
        ) {
            return .failure(error)
        }
        switch store.replaceAllForRecovery(records) {
        case .committed:
            synchronize(
                reservedRegistrations: reservations,
                reservedOwnerDescriptions: ownerDescriptions
            )
            return .success
        case .rejected(rollbackSucceeded: true):
            return .failure(.persistenceFailed)
        case .rejected(rollbackSucceeded: false):
            synchronize(
                reservedRegistrations: reservedRegistrations,
                reservedOwnerDescriptions: reservedOwnerDescriptions
            )
            return .failure(.persistenceRollbackFailed)
        }
    }

    func validateImport(
        _ records: [ActionShortcutAssignmentRecord],
        reservedRegistrations: [GlobalShortcutManager.Registration],
        reservedOwnerDescriptions: [String: String]
    ) -> ActionShortcutMutationResult {
        let records = migratedAssignments(records)
        if let error = importValidationError(
            records,
            reservedRegistrations: reservedRegistrations,
            reservedOwnerDescriptions: reservedOwnerDescriptions
        ) {
            return .failure(error)
        }
        return .success
    }

    private func importValidationError(
        _ records: [ActionShortcutAssignmentRecord],
        reservedRegistrations: [GlobalShortcutManager.Registration],
        reservedOwnerDescriptions: [String: String]
    ) -> ActionShortcutAssignmentError? {
        var seenBindings: [ShortcutBinding: ActionShortcutAssignmentRecord] = [:]
        for record in records {
            guard record.binding.isValid,
                  MacToolsReservedShortcutBindings.validationError(for: record.binding) == nil else {
                return .invalidBinding(.missingModifier)
            }
            if let reserved = reservedRegistrations.first(where: {
                $0.binding == record.binding
            }) {
                return .conflict(
                        ownerDescription: reservedOwnerDescriptions[reserved.shortcutID]
                            ?? reserved.shortcutID
                )
            }
            if let conflict = seenBindings[record.binding] {
                return .conflict(ownerDescription: title(for: conflict.reference))
            }
            seenBindings[record.binding] = record
        }
        return nil
    }

    func synchronize(
        reservedRegistrations: [GlobalShortcutManager.Registration],
        reservedOwnerDescriptions: [String: String]
    ) {
        self.reservedRegistrations = reservedRegistrations
        self.reservedOwnerDescriptions = reservedOwnerDescriptions

        let records = migrateStoredAssignmentsIfPossible()
        var registrations = reservedRegistrations
        var references: [String: ActionReference] = [:]
        var states: [UUID: ActionShortcutRegistrationState] = [:]
        var claimedBindings = Dictionary(
            reservedRegistrations.map { ($0.binding, $0.shortcutID) },
            uniquingKeysWith: { first, _ in first }
        )

        for record in records {
            guard record.binding.isValid,
                  MacToolsReservedShortcutBindings.validationError(for: record.binding) == nil else {
                states[record.id] = .invalidBinding
                continue
            }
            guard case let .success(action) = registry.registeredAction(for: record.reference),
                  action.catalogEntry != nil else {
                states[record.id] = .unavailable(reason: FeatureL10n.string("操作不可用。"))
                continue
            }
            guard action.definition.capabilities.contains(.foregroundInteractive) else {
                states[record.id] = .unavailable(reason: FeatureL10n.string("操作不可用。"))
                continue
            }
            let availability = registry.availability(for: record.reference)
            guard availability.isAvailable else {
                states[record.id] = .unavailable(reason: availability.reason)
                continue
            }
            if let ownerID = claimedBindings[record.binding] {
                states[record.id] = .conflict(
                    ownerDescription: reservedOwnerDescriptions[ownerID]
                        ?? records.first(where: {
                            Self.shortcutID(for: $0.id) == ownerID
                        }).map { title(for: $0.reference) }
                        ?? ownerID
                )
                continue
            }

            let shortcutID = Self.shortcutID(for: record.id)
            registrations.append(
                GlobalShortcutManager.Registration(
                    shortcutID: shortcutID,
                    binding: record.binding
                )
            )
            references[shortcutID] = record.reference
            claimedBindings[record.binding] = shortcutID
        }

        let registrationStatuses = shortcutManager.updateBindings(registrations)
        for record in records where states[record.id] == nil {
            let shortcutID = Self.shortcutID(for: record.id)
            switch registrationStatuses[shortcutID] {
            case .registered:
                states[record.id] = .registered
            case let .failed(.system(code)):
                states[record.id] = .registrationFailed(code: code)
            case .failed(.invalidBinding), .none:
                states[record.id] = .invalidBinding
            }
        }

        referencesByShortcutID = references
        let nextSettingsItems = records.map { record in
            let entry = try? registry.registeredAction(for: record.reference).get()
            return ActionShortcutSettingsItem(
                assignment: record,
                title: entry?.catalogEntry?.title ?? entry?.definition.title ?? record.reference.key.id,
                subtitle: entry?.catalogEntry?.subtitle,
                state: states[record.id] ?? .unavailable(reason: nil)
            )
        }
        if settingsItems != nextSettingsItems {
            settingsItems = nextSettingsItems
            revision &+= 1
        }
    }

    private func migrateStoredAssignmentsIfPossible() -> [ActionShortcutAssignmentRecord] {
        let stored = store.assignments()
        let migrated = migratedAssignments(stored)
        guard migrated != stored else {
            return stored
        }
        switch store.replaceAll(migrated) {
        case .committed:
            return migrated
        case .rejected(rollbackSucceeded: true):
            return stored
        case .rejected(rollbackSucceeded: false):
            return store.assignments()
        }
    }

    private func migratedAssignments(
        _ records: [ActionShortcutAssignmentRecord]
    ) -> [ActionShortcutAssignmentRecord] {
        var result = records
        for index in result.indices {
            let original = result[index]
            guard case let .success(migrated) = registry.migrate(original.reference),
                  migrated != original.reference else {
                continue
            }
            result[index] = ActionShortcutAssignmentRecord(
                id: original.id,
                reference: migrated,
                binding: original.binding
            )
        }
        return result
    }

    private func title(for reference: ActionReference) -> String {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return reference.key.id
        }
        return action.catalogEntry?.title ?? action.definition.title
    }

    private static func shortcutID(for assignmentID: UUID) -> String {
        shortcutIDPrefix + assignmentID.uuidString.lowercased()
    }
}
