import Foundation

enum SystemSettingsProfilePlanStatus: Equatable, Sendable {
    case ready
    case alreadyMatches
    case requiresLogout
    case requiresRestart
    case guidedManual
    case unsupported(String)
    case unavailable(SystemSettingsProfileUnavailability, String)
    case verificationUnavailable
    case invalidValue
    case unknownSetting

    var canSelect: Bool {
        switch self {
        case .ready, .requiresLogout, .requiresRestart, .verificationUnavailable:
            true
        case .alreadyMatches, .guidedManual, .unsupported, .unavailable, .invalidValue, .unknownSetting:
            false
        }
    }
}

enum SystemSettingsProfileUnavailability: Equatable, Sendable {
    case provider
    case hardware
    case permission
    case systemVersion
}

struct SystemSettingsProfilePlanItem: Identifiable, Equatable, Sendable {
    let settingID: SystemSettingID
    let title: String
    let currentValue: SystemSettingValue?
    let desiredValue: SystemSettingValue
    let status: SystemSettingsProfilePlanStatus
    let isSelected: Bool

    var id: SystemSettingID { settingID }

    func selecting(_ selected: Bool) -> Self {
        Self(
            settingID: settingID,
            title: title,
            currentValue: currentValue,
            desiredValue: desiredValue,
            status: status,
            isSelected: status.canSelect && selected
        )
    }
}

struct SystemSettingsProfileApplyPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    let profileName: String
    let createdAt: Date
    let items: [SystemSettingsProfilePlanItem]

    init(
        id: UUID = UUID(),
        profileID: UUID,
        profileName: String,
        createdAt: Date = Date(),
        items: [SystemSettingsProfilePlanItem]
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.createdAt = createdAt
        self.items = items
    }

    func selecting(_ selectedIDs: Set<SystemSettingID>) -> Self {
        Self(
            id: id,
            profileID: profileID,
            profileName: profileName,
            createdAt: createdAt,
            items: items.map { $0.selecting(selectedIDs.contains($0.settingID)) }
        )
    }
}

@MainActor
enum SystemSettingsProfilePlanner {
    static func makePlan(
        profile: SystemSettingsProfile,
        catalog: SystemSettingCatalog,
        currentValues: [SystemSettingID: SystemSettingValue],
        availability: [SystemSettingID: SystemSettingAvailability],
        nonMatchingIDs: Set<SystemSettingID> = [],
        date: Date = Date()
    ) -> SystemSettingsProfileApplyPlan {
        let items = profile.entries.map { entry -> SystemSettingsProfilePlanItem in
            guard let record = catalog[entry.settingID] else {
                return .init(
                    settingID: entry.settingID,
                    title: entry.settingID.rawValue,
                    currentValue: nil,
                    desiredValue: entry.desiredValue,
                    status: .unknownSetting,
                    isSelected: false
                )
            }
            let definition = record.definition
            guard definition.isProfileEligible,
                  !definition.isSensitive,
                  definition.portability == .portable else {
                return item(
                    record,
                    entry,
                    currentValues,
                    .unsupported(MacSettingsStrings.text("This setting cannot be applied through a profile.")),
                    selected: false
                )
            }
            guard definition.acceptsPortableValue(entry.desiredValue) else {
                return item(record, entry, currentValues, .invalidValue, selected: false)
            }
            let current = currentValues[entry.settingID]
            if current == entry.desiredValue, !nonMatchingIDs.contains(entry.settingID) {
                return item(record, entry, currentValues, .alreadyMatches, selected: false)
            }
            let status: SystemSettingsProfilePlanStatus
            switch availability[entry.settingID] ?? .available {
            case .available:
                status = definition.verificationAvailable ? .ready : .verificationUnavailable
            case .requiresLogout:
                status = .requiresLogout
            case .requiresRestart:
                status = .requiresRestart
            case let .providerUnavailable(providerID):
                status = .unavailable(.provider, MacSettingsStrings.format("Missing plugin: %@", "\(providerID)"))
            case let .hardwareUnavailable(hardware):
                status = .unavailable(.hardware, MacSettingsStrings.format("Missing hardware: %@", "\(hardware)"))
            case let .permissionMissing(permission):
                status = .unavailable(.permission, MacSettingsStrings.format("Missing permission: %@", "\(permission)"))
            case .guidedManual:
                status = .guidedManual
            case .managedOnly:
                status = .unsupported(MacSettingsStrings.text("This setting can only be managed by your organization."))
            case let .unsupported(reason):
                status = .unsupported(reason)
            case .systemVersionUnsupported:
                status = .unavailable(.systemVersion, MacSettingsStrings.text("This macOS version is not supported."))
            }
            return item(record, entry, currentValues, status, selected: status.canSelect)
        }
        return .init(
            profileID: profile.id,
            profileName: profile.name,
            createdAt: date,
            items: items
        )
    }

    private static func item(
        _ record: SystemSettingRecord,
        _ entry: SystemSettingsProfileEntry,
        _ currentValues: [SystemSettingID: SystemSettingValue],
        _ status: SystemSettingsProfilePlanStatus,
        selected: Bool
    ) -> SystemSettingsProfilePlanItem {
        .init(
            settingID: entry.settingID,
            title: record.definition.title,
            currentValue: currentValues[entry.settingID],
            desiredValue: entry.desiredValue,
            status: status,
            isSelected: selected
        )
    }
}

enum SystemSettingsProfileApplyResultKind: String, Codable, Sendable {
    case appliedAndVerified
    case alreadyMatched
    case pendingLogout
    case pendingRestart
    case skippedByUser
    case guidedManual
    case unsupported
    case providerUnavailable
    case hardwareUnavailable
    case permissionMissing
    case systemVersionUnavailable
    case failedAndRolledBack
    case failedWithoutRollback
    case verificationUnavailable
    case previewChanged
    case cancelled
}

struct SystemSettingsProfileApplyResult: Identifiable, Equatable, Sendable {
    let settingID: SystemSettingID
    let title: String
    let kind: SystemSettingsProfileApplyResultKind
    let message: String?
    let previousValue: SystemSettingValue?
    let previousSnapshot: SystemSettingSnapshot?

    init(
        settingID: SystemSettingID,
        title: String,
        kind: SystemSettingsProfileApplyResultKind,
        message: String?,
        previousValue: SystemSettingValue? = nil,
        previousSnapshot: SystemSettingSnapshot? = nil
    ) {
        self.settingID = settingID
        self.title = title
        self.kind = kind
        self.message = message
        self.previousValue = previousValue
        self.previousSnapshot = previousSnapshot
    }

    var id: SystemSettingID { settingID }
}

struct SystemSettingRollbackSnapshotEntry: Codable, Equatable, Sendable {
    let settingID: SystemSettingID
    let value: SystemSettingValue
    let snapshot: SystemSettingSnapshot?

    init(settingID: SystemSettingID, value: SystemSettingValue, snapshot: SystemSettingSnapshot? = nil) {
        self.settingID = settingID
        self.value = value
        self.snapshot = snapshot
    }
}

struct SystemSettingRollbackPoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let profileID: UUID
    let entries: [SystemSettingRollbackSnapshotEntry]
}

struct SystemSettingsProfileApplyReport: Identifiable, Equatable, Sendable {
    let id: UUID
    let planID: UUID
    let completedAt: Date
    let results: [SystemSettingsProfileApplyResult]
    let rollbackPoint: SystemSettingRollbackPoint

    var hasPartialSuccess: Bool {
        let kinds = Set(results.map(\.kind))
        let successKinds: Set<SystemSettingsProfileApplyResultKind> = [
            .appliedAndVerified, .alreadyMatched, .pendingLogout, .pendingRestart,
        ]
        return !kinds.isSubset(of: successKinds)
    }
}

@MainActor
final class SystemSettingsProfileApplyCoordinator {
    private let catalog: SystemSettingCatalog

    init(catalog: SystemSettingCatalog) {
        self.catalog = catalog
    }

    func apply(
        plan: SystemSettingsProfileApplyPlan,
        date: Date = Date(),
        onProgress: (SystemSettingsProgressEvent) -> Void = { _ in }
    ) async -> SystemSettingsProfileApplyReport {
        var results: [SystemSettingsProfileApplyResult] = []
        var rollbackEntries: [SystemSettingRollbackSnapshotEntry] = []
        var needsRecovery = false
        for item in plan.items {
            let result = needsRecovery && item.isSelected
                ? result(item, kind: .cancelled, message: MacSettingsStrings.text("Restoration is incomplete. Remaining settings were not applied."))
                : await apply(item: item, onProgress: onProgress)
            results.append(result)
            if result.kind == .failedWithoutRollback, result.previousSnapshot != nil { needsRecovery = true }
            onProgress(.finished(result))
            await Task.yield()
            if item.isSelected,
               let previousValue = result.previousValue,
               let record = catalog[item.settingID],
               record.definition.canRollback,
               (previousValue != item.desiredValue || result.previousSnapshot?.hasRestorationData == true),
               [.appliedAndVerified, .pendingLogout, .pendingRestart, .verificationUnavailable]
                   .contains(result.kind) {
                rollbackEntries.append(.init(
                    settingID: item.settingID, value: previousValue, snapshot: result.previousSnapshot
                ))
            }
        }
        let rollbackPoint = SystemSettingRollbackPoint(
            id: UUID(),
            createdAt: date,
            profileID: plan.profileID,
            entries: rollbackEntries
        )
        return .init(
            id: UUID(),
            planID: plan.id,
            completedAt: date,
            results: results,
            rollbackPoint: rollbackPoint
        )
    }

    func rollback(
        _ point: SystemSettingRollbackPoint,
        onProgress: (SystemSettingsProgressEvent) -> Void = { _ in }
    ) async -> [SystemSettingsProfileApplyResult] {
        var results: [SystemSettingsProfileApplyResult] = []
        for entry in point.entries.reversed() {
            guard let record = catalog[entry.settingID] else { continue }
            do {
                try Task.checkCancellation()
                onProgress(.phase(entry.settingID, .reading))
                let previousSnapshot = try await record.adapter.snapshot()
                try Task.checkCancellation()
                guard entry.snapshot == nil || entry.snapshot?.value == entry.value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                // Settle the current restoration before observing cancellation for the next entry.
                onProgress(.phase(entry.settingID, .restoring))
                let verification = try await record.adapter.restore(entry.snapshot ?? .init(value: entry.value))
                let succeeded: Bool
                if case .verified = verification { succeeded = true } else { succeeded = false }
                results.append(.init(
                    settingID: entry.settingID,
                    title: record.definition.title,
                    kind: succeeded ? .appliedAndVerified : .failedWithoutRollback,
                    message: succeeded ? nil : MacSettingsStrings.text("Rollback verification failed."),
                    previousValue: previousSnapshot.value,
                    previousSnapshot: previousSnapshot
                ))
            } catch is CancellationError {
                results.append(.init(
                    settingID: entry.settingID,
                    title: record.definition.title,
                    kind: .cancelled,
                    message: MacSettingsStrings.text("Rollback was cancelled.")
                ))
            } catch {
                results.append(.init(
                    settingID: entry.settingID,
                    title: record.definition.title,
                    kind: .failedWithoutRollback,
                    message: error.localizedDescription
                ))
            }
            if let result = results.last { onProgress(.finished(result)) }
            await Task.yield()
        }
        return results
    }

    private func apply(
        item: SystemSettingsProfilePlanItem,
        onProgress: (SystemSettingsProgressEvent) -> Void
    ) async -> SystemSettingsProfileApplyResult {
        if !item.isSelected, item.status == .alreadyMatches {
            guard let record = catalog[item.settingID],
                  record.definition.acceptsPortableValue(item.desiredValue) else {
                return result(item, kind: .unsupported, message: MacSettingsStrings.text("This setting cannot be applied through a profile."))
            }
            do {
                try Task.checkCancellation()
                onProgress(.phase(item.settingID, .reading))
                let snapshot = try await record.adapter.snapshot()
                try Task.checkCancellation()
                var matches = snapshot.value == item.desiredValue
                if matches, snapshot.hasRestorationData {
                    matches = try await record.adapter.verify(item.desiredValue) == .verified(item.desiredValue)
                }
                return matches
                    ? result(item, kind: .alreadyMatched)
                    : result(item, kind: .previewChanged, message: MacSettingsStrings.text("The current value has changed. Preview again."))
            } catch is CancellationError {
                return result(item, kind: .cancelled, message: MacSettingsStrings.text("The operation was cancelled."))
            } catch {
                return result(item, kind: .previewChanged, message: error.localizedDescription)
            }
        }
        guard item.isSelected else {
            let outcome: (SystemSettingsProfileApplyResultKind, String?) = switch item.status {
            case .alreadyMatches: (.alreadyMatched, nil)
            case .guidedManual: (.guidedManual, MacSettingsStrings.text("Complete this step manually in System Settings."))
            case let .unsupported(message): (.unsupported, message)
            case .invalidValue: (.unsupported, MacSettingsStrings.text("The profile's value is not valid for this setting."))
            case .unknownSetting: (.unsupported, MacSettingsStrings.text("Unknown settings will not be applied."))
            case let .unavailable(reason, message): (resultKind(for: reason), message)
            default: (.skippedByUser, nil)
            }
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: outcome.0,
                message: outcome.1
            )
        }
        guard let record = catalog[item.settingID] else {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .unsupported,
                message: MacSettingsStrings.text("Unknown settings will not be applied.")
            )
        }
        guard record.definition.isProfileEligible,
              !record.definition.isSensitive,
              record.definition.portability == .portable,
              record.definition.acceptsPortableValue(item.desiredValue) else {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .unsupported,
                message: MacSettingsStrings.text("This setting cannot be applied through a profile.")
            )
        }
        let previousSnapshot: SystemSettingSnapshot
        let alreadyMatches: Bool
        do {
            try Task.checkCancellation()
            onProgress(.phase(item.settingID, .reading))
            previousSnapshot = try await record.adapter.snapshot()
            try Task.checkCancellation()
            guard record.definition.schema.accepts(previousSnapshot.value) else {
                throw SystemSettingAdapterError.invalidValue
            }
            if previousSnapshot.value == item.desiredValue, previousSnapshot.hasRestorationData {
                alreadyMatches = try await record.adapter.verify(item.desiredValue) == .verified(item.desiredValue)
            } else {
                alreadyMatches = previousSnapshot.value == item.desiredValue
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return result(item, kind: .cancelled, message: MacSettingsStrings.text("The operation was cancelled."))
        } catch {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedWithoutRollback,
                message: error.localizedDescription
            )
        }
        let currentValue = previousSnapshot.value
        if alreadyMatches {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .alreadyMatched,
                message: nil,
                previousValue: currentValue
            )
        }
        do {
            // Cancellation stops new settings; an in-flight mutation still needs verification/recovery.
            onProgress(.phase(item.settingID, .applying))
            try await record.adapter.apply(item.desiredValue)
            onProgress(.phase(item.settingID, .verifying))
            let verification = try await record.adapter.verify(item.desiredValue)
            switch verification {
            case .verified:
                let kind: SystemSettingsProfileApplyResultKind = switch item.status {
                case .requiresLogout: .pendingLogout
                case .requiresRestart: .pendingRestart
                default: .appliedAndVerified
                }
                return .init(
                    settingID: item.settingID,
                    title: item.title,
                    kind: kind,
                    message: nil,
                    previousValue: currentValue,
                    previousSnapshot: previousSnapshot
                )
            case .unavailable:
                return .init(
                    settingID: item.settingID,
                    title: item.title,
                    kind: .verificationUnavailable,
                    message: MacSettingsStrings.text("The value was written, but its current state could not be verified."),
                    previousValue: currentValue,
                    previousSnapshot: previousSnapshot
                )
            case let .mismatch(actual):
                onProgress(.phase(item.settingID, .restoring))
                return await rollbackAfterFailure(
                    record: record,
                    item: item,
                    previousSnapshot: previousSnapshot,
                    message: MacSettingsStrings.format("Verification returned %@.", "\(record.definition.displayDescription(for: actual))")
                )
            }
        } catch {
            onProgress(.phase(item.settingID, .restoring))
            return await rollbackAfterFailure(
                record: record,
                item: item,
                previousSnapshot: previousSnapshot,
                message: error.localizedDescription
            )
        }
    }

    private func result(
        _ item: SystemSettingsProfilePlanItem,
        kind: SystemSettingsProfileApplyResultKind,
        message: String? = nil
    ) -> SystemSettingsProfileApplyResult {
        .init(settingID: item.settingID, title: item.title, kind: kind, message: message)
    }

    private func resultKind(
        for reason: SystemSettingsProfileUnavailability
    ) -> SystemSettingsProfileApplyResultKind {
        switch reason {
        case .provider: .providerUnavailable
        case .hardware: .hardwareUnavailable
        case .permission: .permissionMissing
        case .systemVersion: .systemVersionUnavailable
        }
    }

    private func rollbackAfterFailure(
        record: SystemSettingRecord,
        item: SystemSettingsProfilePlanItem,
        previousSnapshot: SystemSettingSnapshot,
        message: String
    ) async -> SystemSettingsProfileApplyResult {
        guard record.definition.canRollback else {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedWithoutRollback,
                message: message
            )
        }
        do {
            let verification = try await record.adapter.restore(previousSnapshot)
            guard case .verified = verification else {
                return .init(
                    settingID: item.settingID,
                    title: item.title,
                    kind: .failedWithoutRollback,
                    message: MacSettingsStrings.format("%@ Rollback verification failed.", "\(message)"),
                    previousValue: previousSnapshot.value,
                    previousSnapshot: previousSnapshot
                )
            }
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedAndRolledBack,
                message: message,
                previousValue: previousSnapshot.value,
                previousSnapshot: previousSnapshot
            )
        } catch {
            return .init(
                settingID: item.settingID,
                title: item.title,
                kind: .failedWithoutRollback,
                message: MacSettingsStrings.format("%@ Rollback failed: %@", "\(message)", "\(error.localizedDescription)"),
                previousValue: previousSnapshot.value,
                previousSnapshot: previousSnapshot
            )
        }
    }
}
