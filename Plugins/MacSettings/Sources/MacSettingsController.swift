import AppKit
import Combine
import Foundation
import MacToolsPluginKit

enum MacSettingsDestination: Hashable, Identifiable {
    case all
    case favorites
    case recent
    case attention
    case category(SystemSettingCategory)
    case profiles
    case importExport
    case history

    var id: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .recent: "recent"
        case .attention: "attention"
        case let .category(category): "category.\(category.rawValue)"
        case .profiles: "profiles"
        case .importExport: "import-export"
        case .history: "history"
        }
    }
}

enum MacSettingsWorkspaceDensity: String, CaseIterable, Codable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }
}

enum MacSettingsPaletteSectionKind: String, Hashable {
    case searchResults
    case favorites
    case attention
    case recent
    case category
}

enum MacSettingsKeyboardFocusTarget: Equatable {
    case search
    case setting(SystemSettingID)
}

enum MacSettingsWorkspaceFocus: Hashable {
    case search
    case setting(SystemSettingID)
}

struct MacSettingsSettingFocusRequest: Equatable {
    let sequence: Int
    let settingID: SystemSettingID
}

enum MacSettingsKeyboardNavigation {
    static func target(
        from currentID: SystemSettingID?,
        movingForward: Bool,
        settingIDs: [SystemSettingID]
    ) -> MacSettingsKeyboardFocusTarget {
        guard !settingIDs.isEmpty else { return .search }
        guard let currentID,
              let index = settingIDs.firstIndex(of: currentID) else {
            return movingForward ? .setting(settingIDs[0]) : .search
        }
        if movingForward {
            return .setting(settingIDs[min(index + 1, settingIDs.count - 1)])
        }
        return index == 0 ? .search : .setting(settingIDs[index - 1])
    }
}

@MainActor
struct MacSettingsPaletteSection {
    let id: String
    let kind: MacSettingsPaletteSectionKind
    let title: String
    let records: [SystemSettingRecord]
}

enum SystemSettingRowVerification: Equatable {
    case verified
    case unverified
    case failed
}

struct SystemSettingRowState: Equatable {
    var value: SystemSettingValue?
    var availability: SystemSettingAvailability
    var isLoading: Bool
    var isApplying: Bool
    var verification: SystemSettingRowVerification?
    var errorMessage: String?
    var changedAt: Date?
    var operationPhase: SystemSettingOperationPhase? = nil
}

struct SystemSettingsImportPreview: Equatable {
    let profile: SystemSettingsProfile
    let validation: SystemSettingsProfileValidationResult
}

@MainActor
final class MacSettingsController: ObservableObject {
    private enum StorageKey {
        static let favorites = "favorite-setting-ids"
        static let density = "workspace-density"
        static let recoveries = "pending-recovery-v1"
    }

    let catalog: SystemSettingCatalog

    @Published var destination: MacSettingsDestination = .all
    @Published var searchText = ""
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var settingFocusRequest: MacSettingsSettingFocusRequest?
    @Published private(set) var rowStates: [SystemSettingID: SystemSettingRowState] = [:]
    @Published private(set) var favoriteIDs: [SystemSettingID]
    @Published private(set) var history: [SystemSettingChange]
    @Published private(set) var profiles: [SystemSettingsProfile]
    @Published private(set) var importedPreview: SystemSettingsImportPreview?
    @Published private(set) var activePlan: SystemSettingsProfileApplyPlan?
    @Published private(set) var lastApplyReport: SystemSettingsProfileApplyReport?
    @Published private(set) var lastRollbackResults: [SystemSettingsProfileApplyResult]?
    @Published private(set) var density: MacSettingsWorkspaceDensity
    @Published private(set) var isRefreshing = false
    @Published private(set) var operationState: SystemSettingsOperationState = .idle
    @Published private(set) var operationProgress: SystemSettingsOperationProgress?
    @Published private(set) var pendingRecoveries: [SystemSettingID: SystemSettingRecovery] = [:]
    @Published private(set) var recoveryPersistenceError: String?
    @Published private(set) var failedDesiredValues: [SystemSettingID: SystemSettingValue] = [:]
    @Published private(set) var profileErrorMessage: String?

    var onStateChange: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)?
    var onPermissionAction: ((String) -> Void)?
    var onOpenSystemSettings: ((URL) -> Void)?
    var onOpenProviderSettings: ((String) -> Void)?

    private let storage: any PluginStorage
    private let historyStore: any SystemSettingChangeHistoryStoring
    private let profileStore: any SystemSettingsProfileStoring
    private let applyCoordinator: SystemSettingsProfileApplyCoordinator
    private var environment: SystemSettingEnvironment
    private var settingFocusSequence = 0
    private var refreshTask: Task<Void, Never>?
    private var externalRefreshTask: Task<Void, Never>?
    private var profileOperationTask: Task<Void, Never>?
    private var planPreparationTask: Task<Void, Never>?
    private var planGeneration: UInt64 = 0
    private var writeTasks: [SystemSettingID: Task<Bool, Never>] = [:]
    private var isActive = true
    private var refreshGeneration: UInt64 = 0
    private var rowRevisions: [SystemSettingID: UInt64] = [:]
    private var applyingSettingIDs: Set<SystemSettingID> = []
    private var pendingRequirementIDs: Set<SystemSettingID> = []
    private var failedSettingIDs: Set<SystemSettingID> = []
    private var rollbackFailureMessages: [SystemSettingID: String] = [:]
    private var retryBaseReport: SystemSettingsProfileApplyReport?

    var isPreparingPlan: Bool { operationState == .preparing }
    var isApplyingProfile: Bool { operationState == .applying || operationState == .restoring }

    init(
        catalog: SystemSettingCatalog,
        storage: any PluginStorage,
        historyStore: (any SystemSettingChangeHistoryStoring)? = nil,
        profileStore: (any SystemSettingsProfileStoring)? = nil,
        environment: SystemSettingEnvironment = .current
    ) {
        self.catalog = catalog
        self.storage = storage
        self.historyStore = historyStore ?? SystemSettingChangeHistoryStore(storage: storage)
        self.profileStore = profileStore ?? SystemSettingsProfileStore(storage: storage)
        self.applyCoordinator = SystemSettingsProfileApplyCoordinator(catalog: catalog)
        self.environment = environment
        let validIDs = Set(catalog.records.map(\.id))
        self.favoriteIDs = (storage.stringArray(forKey: StorageKey.favorites) ?? [])
            .map { SystemSettingID(rawValue: $0) }
            .filter(validIDs.contains)
        self.density = MacSettingsWorkspaceDensity(
            rawValue: storage.string(forKey: StorageKey.density) ?? ""
        ) ?? .comfortable
        self.history = self.historyStore.load(referenceDate: Date())
        self.profiles = self.profileStore.load().filter {
            SystemSettingsProfileCodec.validate($0, catalog: catalog).isValid
        }
        for record in catalog.records {
            rowStates[record.id] = .init(
                value: record.definition.defaultValue,
                availability: SystemSettingCompatibilityEvaluator.availability(
                    for: record.definition,
                    environment: environment
                ),
                isLoading: record.definition.executionClass != .guidedManual
                    && record.definition.executionClass != .unsupported,
                isApplying: false,
                verification: nil,
                errorMessage: nil,
                changedAt: history.first(where: { $0.settingID == record.id })?.date
            )
        }
        if let data = storage.data(forKey: StorageKey.recoveries),
           let entries = try? JSONDecoder().decode([SystemSettingRecovery].self, from: data) {
            for entry in entries {
                guard let record = catalog[entry.settingID], record.definition.canRollback,
                      record.definition.schema.accepts(entry.original.value) else { continue }
                pendingRecoveries[entry.settingID] = entry
                // Persisted observations are not evidence of the current macOS state.
                pendingRecoveries[entry.settingID]?.current = nil
                rollbackFailureMessages[entry.settingID] = entry.message
                rowStates[entry.settingID]?.errorMessage = entry.message
                failedSettingIDs.insert(entry.settingID)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        externalRefreshTask?.cancel()
        profileOperationTask?.cancel()
        planPreparationTask?.cancel()
        for task in writeTasks.values { task.cancel() }
    }

    var visibleRecords: [SystemSettingRecord] {
        catalog.search(searchText, in: records(for: destination))
    }

    var paletteSections: [MacSettingsPaletteSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let records = catalog.search(query)
            guard !records.isEmpty else { return [] }
            return [.init(id: "search-results", kind: .searchResults, title: MacSettingsStrings.text("Search Results"), records: records)]
        }

        switch destination {
        case .all:
            let pinnedIDs = Set(favoriteIDs)
            let categories: [MacSettingsPaletteSection] = availableCategories.compactMap { category in
                let records = records(for: .category(category)).filter { !pinnedIDs.contains($0.id) }
                guard !records.isEmpty else { return nil }
                return .init(
                    id: "category.\(category.rawValue)",
                    kind: .category,
                    title: category.title,
                    records: records
                )
            }
            return section(kind: .favorites, title: MacSettingsStrings.text("Pinned"), records: favoriteRecords) + categories
        case .favorites:
            return section(kind: .favorites, title: MacSettingsStrings.text("Pinned"), records: favoriteRecords)
        case .recent:
            return section(kind: .recent, title: MacSettingsStrings.text("Recently Changed"), records: recentRecords)
        case .attention:
            return section(kind: .attention, title: MacSettingsStrings.text("Needs Attention"), records: attentionRecords)
        case let .category(category):
            return section(
                id: "category.\(category.rawValue)",
                kind: .category,
                title: category.title,
                records: records(for: .category(category))
            )
        case .profiles, .importExport, .history:
            return []
        }
    }

    var favoriteRecords: [SystemSettingRecord] {
        favoriteIDs.compactMap { catalog[$0] }
    }

    var recentRecords: [SystemSettingRecord] {
        var recentIDs: [SystemSettingID] = []
        for change in history where !recentIDs.contains(change.settingID) {
            recentIDs.append(change.settingID)
        }
        return recentIDs.compactMap { catalog[$0] }
    }

    var attentionRecords: [SystemSettingRecord] {
        catalog.records.filter { needsAttention($0.id) }
    }

    var favoriteRecordsForFeaturePanel: [SystemSettingRecord] {
        let favoriteSet = Set(favoriteIDs.prefix(4))
        return favoriteIDs.prefix(4).compactMap { id in
            guard favoriteSet.contains(id) else { return nil }
            return catalog[id]
        }
    }

    var attentionCount: Int {
        catalog.records.lazy.filter { self.needsAttention($0.id) }.count
    }

    var availableCategories: [SystemSettingCategory] {
        SystemSettingCategory.allCases.filter { category in
            catalog.records.contains { $0.definition.category == category }
        }
    }

    var builtInTemplates: [SystemSettingsProfile] {
        BuiltInSystemSettingsProfiles.templates(catalog: catalog)
    }

    func requestSearchFocus() {
        destination = .all
        searchFocusRequest &+= 1
    }

    func showCategoryResults(_ category: SystemSettingCategory) {
        destination = .all
        searchText = category.title
        searchFocusRequest &+= 1
    }

    func showSetting(_ settingID: SystemSettingID) {
        guard catalog[settingID] != nil else { return }
        destination = .all
        searchText = ""
        settingFocusSequence &+= 1
        settingFocusRequest = .init(
            sequence: settingFocusSequence,
            settingID: settingID
        )
    }

    func consumeSettingFocusRequest(_ request: MacSettingsSettingFocusRequest) {
        guard settingFocusRequest == request else { return }
        settingFocusRequest = nil
    }

    func showPalette() {
        destination = .all
        searchFocusRequest &+= 1
    }

    func showPaletteHome() {
        searchText = ""
        showPalette()
    }

    func updateAvailableProviderIDs(_ providerIDs: Set<String>) {
        updateProviderAvailability(Dictionary(uniqueKeysWithValues: providerIDs.map { ($0, .available) }))
    }

    func updateProviderAvailability(_ providers: [String: ActionAvailability]) {
        let providerIDs = Set(providers.filter { $0.value.isAvailable }.keys)
        let reasons = providers.filter { !$0.value.isAvailable }.mapValues { $0.reason ?? MacSettingsStrings.text("The plugin is currently unavailable.") }
        guard environment.availableProviderIDs != providerIDs
            || environment.unavailableProviderReasons != reasons else { return }
        environment = SystemSettingEnvironment(
            systemVersion: environment.systemVersion,
            availableHardware: environment.availableHardware,
            grantedPermissionIDs: environment.grantedPermissionIDs,
            availableProviderIDs: providerIDs,
            unavailableProviderReasons: reasons
        )
        for record in catalog.records where record.definition.requirements.existingProviderID != nil {
            rowRevisions[record.id, default: 0] &+= 1
            rowStates[record.id]?.availability = SystemSettingCompatibilityEvaluator.availability(
                for: record.definition,
                environment: environment
            )
            if let providerID = record.definition.requirements.existingProviderID,
               providerIDs.contains(providerID), rollbackFailureMessages[record.id] == nil {
                rowStates[record.id]?.errorMessage = nil
                failedSettingIDs.remove(record.id)
            }
        }
        scheduleExternalRefresh()
        onStateChange?()
    }

    func refresh() {
        guard isActive else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isRefreshing = true
            defer {
                if refreshGeneration == generation {
                    isRefreshing = false
                    refreshTask = nil
                }
            }
            for record in catalog.records {
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                await refresh(record, refreshGeneration: generation)
                await Task.yield()
            }
            if !Task.isCancelled, refreshGeneration == generation {
                onStateChange?()
            }
        }
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        isRefreshing = false
        for id in rowStates.keys where !applyingSettingIDs.contains(id) {
            rowStates[id]?.isLoading = false
        }
    }

    func activate() {
        isActive = true
        onStateChange?()
    }

    func deactivate() {
        isActive = false
        cancelRefresh()
        cancelPlanPreparation()
        profileOperationTask?.cancel()
        for task in writeTasks.values { task.cancel() }
        onStateChange?()
    }

    func scheduleExternalRefresh() {
        guard isActive else { return }
        externalRefreshTask?.cancel()
        externalRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh(_ record: SystemSettingRecord) async {
        await refresh(record, refreshGeneration: nil)
    }

    private func refresh(
        _ record: SystemSettingRecord,
        refreshGeneration expectedRefreshGeneration: UInt64?
    ) async {
        guard isActive, !applyingSettingIDs.contains(record.id) else { return }
        let rowRevision = rowRevisions[record.id, default: 0]
        let availability = SystemSettingCompatibilityEvaluator.availability(
            for: record.definition,
            environment: environment
        )
        rowStates[record.id]?.availability = availability
        guard canRead(availability),
              record.definition.executionClass != .guidedManual,
              record.definition.executionClass != .unsupported else {
            rowStates[record.id]?.isLoading = false
            return
        }
        rowStates[record.id]?.isLoading = true
        do {
            let recoverySnapshot = pendingRecoveries[record.id] != nil ? try await record.adapter.snapshot() : nil
            let value: SystemSettingValue
            if let recoverySnapshot { value = recoverySnapshot.value }
            else { value = try await record.adapter.read() }
            guard canPublishRefresh(
                record.id,
                rowRevision: rowRevision,
                refreshGeneration: expectedRefreshGeneration
            ) else { return }
            guard record.definition.schema.accepts(value) else {
                throw SystemSettingAdapterError.invalidValue
            }
            rowStates[record.id]?.availability = availability
            rowStates[record.id]?.value = value
            if let recoverySnapshot {
                pendingRecoveries[record.id]?.current = recoverySnapshot
                persistRecoveries()
            }
            rowStates[record.id]?.errorMessage = rollbackFailureMessages[record.id]
            if rollbackFailureMessages[record.id] == nil {
                failedSettingIDs.remove(record.id)
            }
        } catch {
            guard canPublishRefresh(
                record.id,
                rowRevision: rowRevision,
                refreshGeneration: expectedRefreshGeneration
            ) else { return }
            rowStates[record.id]?.availability = runtimeFailureAvailability(
                for: record,
                error: error
            )
            rowStates[record.id]?.errorMessage = error.localizedDescription
            if pendingRecoveries[record.id] != nil {
                pendingRecoveries[record.id]?.current = nil
                rowStates[record.id]?.value = nil
                persistRecoveries()
            }
            failedSettingIDs.insert(record.id)
        }
        rowStates[record.id]?.isLoading = false
    }

    var canEditSettings: Bool { isActive && operationState == .idle && pendingRecoveries.isEmpty }
    var canResolveRecovery: Bool { isActive && operationState == .idle && writeTasks.isEmpty }

    @discardableResult
    func apply(_ value: SystemSettingValue, to settingID: SystemSettingID) -> Bool {
        guard canEditSettings,
              let record = catalog[settingID],
              record.definition.schema.accepts(value),
              let state = rowStates[settingID],
              canApply(state.availability),
              state.errorMessage == nil,
              !state.isApplying else { return false }
        return startWrite(value, to: record) != nil
    }

    @discardableResult
    func applyAndWait(
        _ value: SystemSettingValue,
        to record: SystemSettingRecord,
        restoring snapshot: SystemSettingSnapshot? = nil
    ) async -> Bool {
        guard !Task.isCancelled, let task = startWrite(value, to: record, restoring: snapshot) else { return false }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startWrite(
        _ value: SystemSettingValue,
        to record: SystemSettingRecord,
        restoring snapshot: SystemSettingSnapshot? = nil
    ) -> Task<Bool, Never>? {
        guard canEditSettings,
              writeTasks[record.id] == nil else { return nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { writeTasks[record.id] = nil }
            return await performApplyAndWait(value, to: record, restoring: snapshot)
        }
        writeTasks[record.id] = task
        return task
    }

    private func performApplyAndWait(
        _ value: SystemSettingValue,
        to record: SystemSettingRecord,
        restoring snapshot: SystemSettingSnapshot?
    ) async -> Bool {
        guard isActive, !Task.isCancelled,
              record.definition.schema.accepts(value),
              let state = rowStates[record.id],
              canApply(state.availability),
              state.errorMessage == nil,
              !applyingSettingIDs.contains(record.id),
              !isApplyingProfile else { return false }
        applyingSettingIDs.insert(record.id)
        rowRevisions[record.id, default: 0] &+= 1
        rowStates[record.id]?.isApplying = true
        rowStates[record.id]?.isLoading = false
        setRowPhase(.reading, for: record.id)
        defer {
            applyingSettingIDs.remove(record.id)
            rowStates[record.id]?.isApplying = false
            setRowPhase(nil, for: record.id)
        }
        let previousSnapshot: SystemSettingSnapshot
        do {
            previousSnapshot = try await record.adapter.snapshot()
            try Task.checkCancellation()
        } catch is CancellationError {
            return false
        } catch {
            rowStates[record.id]?.availability = runtimeFailureAvailability(for: record, error: error)
            rowStates[record.id]?.errorMessage = error.localizedDescription
            failedSettingIDs.insert(record.id)
            onStateChange?()
            return false
        }

        let previousValue = previousSnapshot.value
        failedDesiredValues[record.id] = value
        rowStates[record.id]?.value = value
        rowStates[record.id]?.errorMessage = nil
        do {
            let verification: SystemSettingVerification
            if let snapshot {
                guard snapshot.value == value else { throw SystemSettingAdapterError.invalidValue }
                setRowPhase(.restoring, for: record.id)
                verification = try await record.adapter.restore(snapshot)
            } else {
                setRowPhase(.applying, for: record.id)
                try await record.adapter.apply(value)
                setRowPhase(.verifying, for: record.id)
                verification = try await record.adapter.verify(value)
            }
            switch verification {
            case .verified:
                rowStates[record.id]?.verification = .verified
                rowStates[record.id]?.value = value
            case .unavailable:
                rowStates[record.id]?.verification = .unverified
            case let .mismatch(actual):
                let rolledBack = await rollbackAfterFailedApply(
                    record: record,
                    previousSnapshot: previousSnapshot
                )
                rowStates[record.id]?.value = rolledBack ? previousValue
                    : (pendingRecoveries[record.id] != nil ? pendingRecoveries[record.id]?.current?.value : actual)
                rowStates[record.id]?.verification = .failed
                rowStates[record.id]?.errorMessage = rolledBack
                    ? MacSettingsStrings.text("Verification failed. The original value was restored.")
                    : MacSettingsStrings.format("Verification failed: the current value is %@, and automatic restoration failed.", "\(record.definition.displayDescription(for: actual))")
                rowStates[record.id]?.availability = runtimeFailureAvailability(
                    for: record,
                    message: rowStates[record.id]?.errorMessage ?? MacSettingsStrings.text("Could not verify the setting.")
                )
                failedSettingIDs.insert(record.id)
                onStateChange?()
                return false
            }
            failedSettingIDs.remove(record.id)
            failedDesiredValues[record.id] = nil
            if record.definition.executionClass == .directRequiresLogout
                || record.definition.executionClass == .directRequiresRestart {
                pendingRequirementIDs.insert(record.id)
            }
            var didChange = previousValue != value
            if previousSnapshot.hasRestorationData {
                didChange = previousSnapshot != (try await record.adapter.snapshot())
            }
            if didChange, !record.definition.isSensitive {
                let change = SystemSettingChange(
                    settingID: record.id,
                    settingTitle: record.definition.title,
                    previousValue: previousValue,
                    newValue: value,
                    verification: verification == .unavailable ? .unverified : .verified,
                    canRollback: record.definition.canRollback,
                    previousSnapshot: previousSnapshot
                )
                history = historyStore.append(change, referenceDate: change.date)
                rowStates[record.id]?.changedAt = change.date
            }
            onStateChange?()
            return true
        } catch {
            let rolledBack = await rollbackAfterFailedApply(
                record: record,
                previousSnapshot: previousSnapshot
            )
            if rolledBack {
                rowStates[record.id]?.value = previousValue
            }
            rowStates[record.id]?.verification = .failed
            rowStates[record.id]?.errorMessage = rolledBack
                ? MacSettingsStrings.format("%@ The original value was restored.", "\(error.localizedDescription)")
                : MacSettingsStrings.format("%@ Automatic restoration failed.", "\(error.localizedDescription)")
            rowStates[record.id]?.availability = runtimeFailureAvailability(
                for: record,
                error: error
            )
            failedSettingIDs.insert(record.id)
            onStateChange?()
            return false
        }
    }

    private func rollbackAfterFailedApply(
        record: SystemSettingRecord,
        previousSnapshot: SystemSettingSnapshot
    ) async -> Bool {
        guard record.definition.canRollback else { return false }
        setRowPhase(.restoring, for: record.id)
        do {
            guard case .verified = try await record.adapter.restore(previousSnapshot) else {
                await retainRecovery(record: record, original: previousSnapshot, message: MacSettingsStrings.text("Restoration is incomplete. Retry Restoration or Keep Current Values to continue."))
                return false
            }
            return true
        } catch {
            await retainRecovery(record: record, original: previousSnapshot, message: MacSettingsStrings.format("Restoration is incomplete: %@", "\(error.localizedDescription)"))
            return false
        }
    }

    func toggleFavorite(_ settingID: SystemSettingID) {
        var updatedFavoriteIDs = favoriteIDs
        if let index = updatedFavoriteIDs.firstIndex(of: settingID) {
            updatedFavoriteIDs.remove(at: index)
        } else if catalog[settingID] != nil {
            updatedFavoriteIDs.append(settingID)
        }
        guard updatedFavoriteIDs != favoriteIDs else { return }
        favoriteIDs = updatedFavoriteIDs
        persistFavorites()
    }

    func showFavorites() {
        searchText = ""
        destination = .favorites
        onStateChange?()
    }

    func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        favoriteIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistFavorites()
    }

    func moveFavorite(_ settingID: SystemSettingID, by offset: Int) {
        guard let index = favoriteIDs.firstIndex(of: settingID) else { return }
        let destination = index + offset
        guard favoriteIDs.indices.contains(destination) else { return }
        favoriteIDs.swapAt(index, destination)
        persistFavorites()
    }

    func setDensity(_ density: MacSettingsWorkspaceDensity) {
        self.density = density
        storage.set(density.rawValue, forKey: StorageKey.density)
        onPersistentPreferencesChange?()
    }

    func clearHistory() {
        historyStore.clear()
        history = []
        for id in rowStates.keys {
            rowStates[id]?.changedAt = nil
        }
        onStateChange?()
    }

    func rollback(_ change: SystemSettingChange) {
        guard change.canRollback, let record = catalog[change.settingID] else { return }
        _ = startWrite(
            change.previousValue, to: record,
            restoring: change.previousSnapshot ?? .init(value: change.previousValue)
        )
    }

    func openProviderSettings(for settingID: SystemSettingID) {
        guard let providerID = catalog[settingID]?.definition.requirements.existingProviderID else { return }
        onOpenProviderSettings?(providerID)
    }

    func openSystemSettings(for settingID: SystemSettingID) {
        if case let .permissionMissing(permissionID) = rowStates[settingID]?.availability {
            if let onPermissionAction {
                onPermissionAction(permissionID)
            } else if permissionID == MacSettingsPermission.fullDiskAccess,
                      let url = MacSettingsPermission.fullDiskAccessSettingsURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let url = catalog[settingID]?.definition.destination?.url else { return }
        if let onOpenSystemSettings {
            onOpenSystemSettings(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func isPermissionGranted(_ permissionID: String) -> Bool {
        environment.grantedPermissionIDs.contains(permissionID)
    }

    func makeDraft(from profile: SystemSettingsProfile? = nil) -> SystemSettingsProfileDraft {
        let entryByID = Dictionary(uniqueKeysWithValues: (profile?.entries ?? []).map { ($0.settingID, $0) })
        return SystemSettingsProfileDraft(
            name: profile?.name ?? MacSettingsStrings.text("New Profile"),
            profileDescription: profile?.profileDescription ?? "",
            items: catalog.records.filter(\.definition.isProfileEligible).map { record in
                let existing = entryByID[record.id]
                let current = rowStates[record.id]?.value.flatMap {
                    record.definition.acceptsPortableValue($0) ? $0 : nil
                }
                return .init(
                    settingID: record.id,
                    isIncluded: existing != nil,
                    desiredValue: existing?.desiredValue
                        ?? current
                        ?? record.definition.defaultValue
                        ?? .string("")
                )
            }
        )
    }

    @discardableResult
    func saveDraft(
        _ draft: SystemSettingsProfileDraft,
        replacing profile: SystemSettingsProfile? = nil
    ) -> Bool {
        let saved = draft.makeProfile(existing: profile, catalog: catalog)
        let validation = SystemSettingsProfileCodec.validate(saved, catalog: catalog)
        if let message = draftValidationMessage(draft, replacing: profile) {
            profileErrorMessage = message
            return false
        }
        guard validation.isValid, profileStore.save(saved) else {
            profileErrorMessage = MacSettingsStrings.text("Could not save the profile. Check the profile count and available storage, then try again.")
            return false
        }
        profiles = profileStore.load()
        profileErrorMessage = nil
        onPersistentPreferencesChange?()
        onStateChange?()
        return true
    }

    func draftValidationMessage(
        _ draft: SystemSettingsProfileDraft,
        replacing profile: SystemSettingsProfile? = nil
    ) -> String? {
        let saved = draft.makeProfile(existing: profile, catalog: catalog)
        if saved.name.isEmpty { return MacSettingsStrings.text("Enter a profile name.") }
        if saved.name.count > SystemSettingsProfileCodec.maximumNameLength { return MacSettingsStrings.text("Profile names cannot exceed 120 characters.") }
        if saved.profileDescription.count > SystemSettingsProfileCodec.maximumDescriptionLength {
            return MacSettingsStrings.text("The profile description is too long. Shorten it and try again.")
        }
        if saved.entries.isEmpty { return MacSettingsStrings.text("A profile must include at least one valid setting.") }
        return SystemSettingsProfileCodec.validate(saved, catalog: catalog).isValid
            ? nil : MacSettingsStrings.text("The profile contains invalid settings. Check the selected items.")
    }

    func clearProfileError() { profileErrorMessage = nil }

    func restorePortablePreferences(
        favorites: [SystemSettingID], density: MacSettingsWorkspaceDensity,
        profiles restored: [SystemSettingsProfile]
    ) -> Bool {
        guard Set(restored.map(\.id)).count == restored.count,
              restored.allSatisfy({ SystemSettingsProfileCodec.validate($0, catalog: catalog).isValid }) else { return false }
        let previousProfiles = profileStore.load()
        var merged = previousProfiles.filter { old in !restored.contains { $0.id == old.id } }
        merged.append(contentsOf: restored)
        // Validate and persist the complete profile set in one operation before changing other fields.
        guard profileStore.replaceAll(merged) else { return false }
        let previousFavorites = storage.object(forKey: StorageKey.favorites)
        let previousDensity = storage.object(forKey: StorageKey.density)
        var seen: Set<SystemSettingID> = []
        let favorites = favorites.filter { catalog[$0] != nil && seen.insert($0).inserted }
        let rawFavorites = favorites.map(\.rawValue)
        storage.set(rawFavorites, forKey: StorageKey.favorites)
        storage.set(density.rawValue, forKey: StorageKey.density)
        guard storage.stringArray(forKey: StorageKey.favorites) == rawFavorites,
              storage.string(forKey: StorageKey.density) == density.rawValue else {
            storage.set(previousFavorites, forKey: StorageKey.favorites)
            storage.set(previousDensity, forKey: StorageKey.density)
            _ = profileStore.replaceAll(previousProfiles)
            return false
        }
        favoriteIDs = favorites
        self.density = density
        profiles = profileStore.load()
        onPersistentPreferencesChange?()
        onStateChange?()
        return true
    }

    func saveTemplate(_ template: SystemSettingsProfile) {
        var copy = template
        copy = SystemSettingsProfile(
            name: template.name,
            profileDescription: template.profileDescription,
            entries: template.entries
        )
        if profileStore.save(copy) {
            profiles = profileStore.load()
            onPersistentPreferencesChange?()
            onStateChange?()
        }
    }

    func removeProfile(_ profile: SystemSettingsProfile) {
        guard profileStore.remove(id: profile.id) else { return }
        profiles = profileStore.load()
        if importedPreview?.profile.id == profile.id { importedPreview = nil }
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func importProfile(data: Data) {
        guard isActive, !isApplyingProfile else { return }
        do {
            let decoded = try SystemSettingsProfileCodec.decode(data, catalog: catalog)
            importedPreview = .init(profile: decoded.0, validation: decoded.1)
            profileErrorMessage = nil
        } catch {
            cancelPlanPreparation()
            importedPreview = nil
            activePlan = nil
            profileErrorMessage = MacSettingsStrings.format("Could not import the profile: %@", "\(error.localizedDescription)")
        }
    }

    func reportProfileImportFailure(_ error: Error) {
        cancelPlanPreparation()
        importedPreview = nil
        activePlan = nil
        profileErrorMessage = MacSettingsStrings.format("Could not import the profile: %@", "\(error.localizedDescription)")
    }

    @discardableResult
    func acceptImportedProfile() -> Bool {
        guard let profile = importedPreview?.profile else {
            profileErrorMessage = MacSettingsStrings.text(
                "Could not save the profile. Check the profile count and available storage, then try again."
            )
            return false
        }
        guard profileStore.save(profile) else {
            profileErrorMessage = MacSettingsStrings.text(
                "Could not save the profile. Check the profile count and available storage, then try again."
            )
            return false
        }
        profiles = profileStore.load()
        profileErrorMessage = nil
        onPersistentPreferencesChange?()
        onStateChange?()
        return true
    }

    func exportData(for profile: SystemSettingsProfile) throws -> Data {
        try SystemSettingsProfileCodec.encode(profile, catalog: catalog)
    }

    func makePlan(for profile: SystemSettingsProfile) async throws -> SystemSettingsProfileApplyPlan {
        var currentValues: [SystemSettingID: SystemSettingValue] = [:]
        var availability: [SystemSettingID: SystemSettingAvailability] = [:]
        var nonMatchingIDs: Set<SystemSettingID> = []
        for entry in profile.entries {
            try Task.checkCancellation()
            guard let record = catalog[entry.settingID] else { continue }
            let compatible = SystemSettingCompatibilityEvaluator.availability(
                for: record.definition,
                environment: environment
            )
            availability[entry.settingID] = compatible
            guard record.definition.isProfileEligible, canApply(compatible) else { continue }
            do {
                let snapshot = try await record.adapter.snapshot()
                let current = snapshot.value
                guard record.definition.schema.accepts(current) else {
                    throw SystemSettingAdapterError.invalidValue
                }
                currentValues[entry.settingID] = current
                if current == entry.desiredValue, snapshot.hasRestorationData,
                   try await record.adapter.verify(entry.desiredValue) != .verified(entry.desiredValue) {
                    nonMatchingIDs.insert(entry.settingID)
                }
            } catch {
                availability[entry.settingID] = runtimeFailureAvailability(for: record, error: error)
            }
            try Task.checkCancellation()
        }
        return SystemSettingsProfilePlanner.makePlan(
            profile: profile,
            catalog: catalog,
            currentValues: currentValues,
            availability: availability,
            nonMatchingIDs: nonMatchingIDs
        )
    }

    func preparePlan(for profile: SystemSettingsProfile) {
        guard isActive, !isApplyingProfile, writeTasks.isEmpty, pendingRecoveries.isEmpty else { return }
        cancelPlanPreparation()
        let generation = planGeneration
        activePlan = nil
        lastApplyReport = nil
        lastRollbackResults = nil
        retryBaseReport = nil
        transitionOperation(to: .preparing)
        planPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if planGeneration == generation {
                    planPreparationTask = nil
                    transitionOperation(to: .idle)
                }
            }
            guard let plan = try? await makePlan(for: profile),
                  !Task.isCancelled, isActive, planGeneration == generation else { return }
            activePlan = plan
        }
    }

    private func cancelPlanPreparation() {
        planGeneration &+= 1
        planPreparationTask?.cancel()
        planPreparationTask = nil
        if isPreparingPlan { transitionOperation(to: .idle) }
    }

    func updatePlanSelection(_ selectedIDs: Set<SystemSettingID>) {
        guard !isApplyingProfile else { return }
        activePlan = activePlan?.selecting(selectedIDs)
    }

    func dismissActivePlan() {
        guard !isApplyingProfile, !isPreparingPlan else { return }
        activePlan = nil
        lastApplyReport = nil
        lastRollbackResults = nil
        retryBaseReport = nil
        onStateChange?()
    }

    func applyActivePlan() {
        guard canEditSettings, writeTasks.isEmpty,
              let plan = activePlan,
              !isApplyingProfile,
              applyingSettingIDs.isEmpty else { return }
        let settingIDs = Set(plan.items.filter(\.isSelected).map(\.settingID))
        guard beginProfileOperation(settingIDs: settingIDs, state: .applying, total: plan.items.count) else { return }
        profileOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishProfileOperation(settingIDs: settingIDs) }
            let attempt = await applyCoordinator.apply(plan: plan, onProgress: receiveProgress)
            let report = mergedRetryReport(attempt)
            lastApplyReport = report
            lastRollbackResults = nil
            for result in attempt.results {
                if [.appliedAndVerified, .pendingLogout, .pendingRestart, .verificationUnavailable].contains(result.kind),
                   let item = plan.items.first(where: { $0.settingID == result.settingID }),
                   let previous = result.previousValue,
                   (previous != item.desiredValue || result.previousSnapshot?.hasRestorationData == true),
                   let record = catalog[result.settingID],
                   !record.definition.isSensitive {
                    let change = SystemSettingChange(
                        settingID: result.settingID,
                        settingTitle: result.title,
                        previousValue: previous,
                        newValue: item.desiredValue,
                        verification: result.kind == .verificationUnavailable ? .unverified : .verified,
                        canRollback: record.definition.canRollback,
                        previousSnapshot: result.previousSnapshot
                    )
                    history = historyStore.append(change, referenceDate: change.date)
                    rowStates[result.settingID]?.value = item.desiredValue
                    rowStates[result.settingID]?.verification = result.kind == .verificationUnavailable
                        ? .unverified : .verified
                    rowStates[result.settingID]?.errorMessage = nil
                    rollbackFailureMessages[result.settingID] = nil
                    failedSettingIDs.remove(result.settingID)
                    rowStates[result.settingID]?.changedAt = change.date
                }
                if isActive, !Task.isCancelled, let record = catalog[result.settingID] {
                    applyingSettingIDs.remove(result.settingID)
                    rowStates[result.settingID]?.isApplying = false
                    await refresh(record)
                }
                switch result.kind {
                case .pendingLogout, .pendingRestart:
                    pendingRequirementIDs.insert(result.settingID)
                case .failedAndRolledBack, .failedWithoutRollback:
                    failedSettingIDs.insert(result.settingID)
                    rowStates[result.settingID]?.errorMessage = result.message
                    if let record = catalog[result.settingID] {
                        if result.kind == .failedWithoutRollback, let original = result.previousSnapshot {
                            await retainRecovery(record: record, original: original, message: result.message ?? MacSettingsStrings.text("Restoration is incomplete."))
                        }
                        rowStates[result.settingID]?.availability = runtimeFailureAvailability(
                            for: record,
                            message: result.message ?? MacSettingsStrings.text("Could not apply the setting.")
                        )
                    }
                default:
                    break
                }
            }
            onStateChange?()
        }
    }

    func rollbackLastApply() {
        guard isActive, !isPreparingPlan, writeTasks.isEmpty,
              let originalPoint = lastApplyReport?.rollbackPoint,
              !isApplyingProfile,
              applyingSettingIDs.isEmpty else { return }
        let restoredIDs = Set((lastRollbackResults ?? [])
            .filter { [.appliedAndVerified, .skippedByUser].contains($0.kind) }.map(\.settingID))
        let point = SystemSettingRollbackPoint(
            id: originalPoint.id,
            createdAt: originalPoint.createdAt,
            profileID: originalPoint.profileID,
            entries: originalPoint.entries.filter { !restoredIDs.contains($0.settingID) }
        )
        guard !point.entries.isEmpty else { return }
        let settingIDs = Set(point.entries.map(\.settingID))
        guard beginProfileOperation(settingIDs: settingIDs, state: .restoring, total: point.entries.count) else { return }
        profileOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishProfileOperation(settingIDs: settingIDs) }
            let results = await applyCoordinator.rollback(point) { event in
                receiveRestorationProgress(event, point: point)
            }
            var outcomes = Dictionary(uniqueKeysWithValues: (lastRollbackResults ?? []).map {
                ($0.settingID, $0)
            })
            for result in results { outcomes[result.settingID] = result }
            lastRollbackResults = originalPoint.entries.compactMap { outcomes[$0.settingID] }
            for result in results {
                if let record = catalog[result.settingID] {
                    applyingSettingIDs.remove(result.settingID)
                    rowStates[result.settingID]?.isApplying = false
                    if isActive, !Task.isCancelled { await refresh(record) }
                    if result.kind == .appliedAndVerified,
                       let restoredValue = point.entries.first(where: { $0.settingID == result.settingID })?.value {
                        rowStates[result.settingID]?.value = restoredValue
                        rowStates[result.settingID]?.verification = .verified
                        rowStates[result.settingID]?.errorMessage = nil
                        rollbackFailureMessages[result.settingID] = nil
                        pendingRecoveries[result.settingID] = nil
                        persistRecoveries()
                        failedSettingIDs.remove(result.settingID)
                        if let previous = result.previousValue,
                           (previous != restoredValue || result.previousSnapshot?.hasRestorationData == true),
                           !record.definition.isSensitive {
                            let change = SystemSettingChange(
                                settingID: record.id,
                                settingTitle: result.title,
                                previousValue: previous,
                                newValue: restoredValue,
                                verification: .verified,
                                canRollback: record.definition.canRollback,
                                previousSnapshot: result.previousSnapshot
                            )
                            history = historyStore.append(change, referenceDate: change.date)
                            rowStates[result.settingID]?.changedAt = change.date
                        }
                    } else {
                        failedSettingIDs.insert(result.settingID)
                        rowStates[result.settingID]?.verification = .failed
                        rowStates[result.settingID]?.errorMessage = result.message
                        rollbackFailureMessages[result.settingID] = result.message ?? MacSettingsStrings.text("Rollback is incomplete. Try again.")
                        if result.kind != .cancelled,
                           let original = point.entries.first(where: { $0.settingID == result.settingID }) {
                            await retainRecovery(record: record, original: original.snapshot ?? .init(value: original.value), message: result.message ?? MacSettingsStrings.text("Restoration is incomplete."))
                        }
                    }
                }
            }
            onStateChange?()
        }
    }

    var mostRecentUndoableChange: SystemSettingChange? {
        guard canEditSettings else { return nil }
        return history.first { change in
            guard change.canRollback, let record = catalog[change.settingID],
                  record.definition.canRollback,
                  record.definition.schema.accepts(change.previousValue),
                  let state = rowStates[change.settingID] else { return false }
            return canApply(state.availability) && state.errorMessage == nil
                && !state.isApplying && writeTasks[change.settingID] == nil
        }
    }

    func undoMostRecentChange() async -> Bool {
        guard let change = mostRecentUndoableChange,
              let record = catalog[change.settingID] else { return false }
        return await applyAndWait(
            change.previousValue, to: record,
            restoring: change.previousSnapshot ?? .init(value: change.previousValue)
        )
    }

    func needsAttention(_ settingID: SystemSettingID) -> Bool {
        guard let state = rowStates[settingID] else { return false }
        if failedSettingIDs.contains(settingID) || pendingRequirementIDs.contains(settingID) {
            return true
        }
        switch state.availability {
        case .providerUnavailable, .hardwareUnavailable, .permissionMissing:
            return true
        case .available, .requiresLogout, .requiresRestart, .guidedManual, .managedOnly,
             .unsupported, .systemVersionUnsupported:
            return false
        }
    }

    private func records(for destination: MacSettingsDestination) -> [SystemSettingRecord] {
        switch destination {
        case .all:
            catalog.records
        case .favorites:
            favoriteRecords
        case .recent:
            recentRecords
        case .attention:
            attentionRecords
        case let .category(category):
            catalog.records.filter { $0.definition.category == category }
        case .profiles, .importExport, .history:
            []
        }
    }

    private func section(
        id: String? = nil,
        kind: MacSettingsPaletteSectionKind,
        title: String,
        records: [SystemSettingRecord]
    ) -> [MacSettingsPaletteSection] {
        guard !records.isEmpty else { return [] }
        return [.init(id: id ?? kind.rawValue, kind: kind, title: title, records: records)]
    }

    private func persistFavorites() {
        storage.set(favoriteIDs.map(\.rawValue), forKey: StorageKey.favorites)
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    private func canPublishRefresh(
        _ settingID: SystemSettingID,
        rowRevision: UInt64,
        refreshGeneration expectedRefreshGeneration: UInt64?
    ) -> Bool {
        guard !Task.isCancelled,
              rowRevisions[settingID, default: 0] == rowRevision,
              !applyingSettingIDs.contains(settingID) else { return false }
        return expectedRefreshGeneration.map { $0 == refreshGeneration } ?? true
    }

    private func runtimeFailureAvailability(
        for record: SystemSettingRecord,
        error: Error
    ) -> SystemSettingAvailability {
        runtimeFailureAvailability(for: record, message: error.localizedDescription)
    }

    private func runtimeFailureAvailability(
        for record: SystemSettingRecord,
        message: String
    ) -> SystemSettingAvailability {
        let compatibility = SystemSettingCompatibilityEvaluator.availability(
            for: record.definition,
            environment: environment
        )
        if case .permissionMissing = compatibility {
            return compatibility
        }
        if record.definition.executionClass == .hardwareDependent {
            return .hardwareUnavailable(message)
        }
        if let providerID = record.definition.requirements.existingProviderID {
            return .providerUnavailable(providerID)
        }
        return .unsupported(message)
    }

    private func beginProfileOperation(
        settingIDs: Set<SystemSettingID>, state: SystemSettingsOperationState, total: Int
    ) -> Bool {
        guard isActive, !isPreparingPlan, writeTasks.isEmpty, !isApplyingProfile,
              profileOperationTask == nil,
              applyingSettingIDs.isDisjoint(with: settingIDs) else { return false }
        for id in settingIDs {
            applyingSettingIDs.insert(id)
            rowRevisions[id, default: 0] &+= 1
            rowStates[id]?.isApplying = true
            rowStates[id]?.isLoading = false
        }
        transitionOperation(to: state, progress: .init(total: total))
        return true
    }

    private func finishProfileOperation(settingIDs: Set<SystemSettingID>) {
        for id in settingIDs {
            applyingSettingIDs.remove(id)
            rowStates[id]?.isApplying = false
            rowStates[id]?.operationPhase = nil
        }
        profileOperationTask = nil
        transitionOperation(to: .idle, progress: operationProgress)
    }

    private func transitionOperation(
        to state: SystemSettingsOperationState, progress: SystemSettingsOperationProgress? = nil
    ) {
        operationState = state
        operationProgress = progress
        onStateChange?()
    }

    private func setRowPhase(_ phase: SystemSettingOperationPhase?, for id: SystemSettingID) {
        rowStates[id]?.operationPhase = phase
        onStateChange?()
    }

    private func receiveProgress(_ event: SystemSettingsProgressEvent) {
        switch event {
        case let .phase(id, phase):
            operationProgress?.activeSettingID = id
            operationProgress?.phase = phase
            rowStates[id]?.operationPhase = phase
        case let .finished(result):
            operationProgress?.results.append(result)
            operationProgress?.activeSettingID = nil
            operationProgress?.phase = nil
            rowStates[result.settingID]?.operationPhase = nil
            if operationState == .applying {
                switch result.kind {
                case .appliedAndVerified, .pendingLogout, .pendingRestart, .verificationUnavailable, .alreadyMatched:
                    rowStates[result.settingID]?.value = activePlan?.items.first { $0.settingID == result.settingID }?.desiredValue
                    rowStates[result.settingID]?.verification = result.kind == .verificationUnavailable ? .unverified : .verified
                case .failedAndRolledBack:
                    rowStates[result.settingID]?.value = result.previousValue
                    rowStates[result.settingID]?.verification = .failed
                case .failedWithoutRollback:
                    if let original = result.previousSnapshot {
                        stageRecovery(for: result.settingID, original: original, message: result.message ?? MacSettingsStrings.text("Restoration is incomplete."))
                    }
                default:
                    break
                }
            }
        }
        onStateChange?()
    }

    private func receiveRestorationProgress(_ event: SystemSettingsProgressEvent, point: SystemSettingRollbackPoint) {
        if case let .finished(result) = event, result.kind == .appliedAndVerified {
            rowStates[result.settingID]?.value = point.entries.first { $0.settingID == result.settingID }?.value
            rowStates[result.settingID]?.verification = .verified
        } else if case let .finished(result) = event, result.kind == .failedWithoutRollback,
                  let entry = point.entries.first(where: { $0.settingID == result.settingID }) {
            stageRecovery(for: result.settingID, original: entry.snapshot ?? .init(value: entry.value),
                          message: result.message ?? MacSettingsStrings.text("Restoration is incomplete."))
        }
        receiveProgress(event)
    }

    func cancelOperation() {
        if isPreparingPlan { cancelPlanPreparation() }
        else { profileOperationTask?.cancel() }
        // In-flight writes finish verification/recovery before becoming idle.
    }

    func retryFailedChange(_ id: SystemSettingID) {
        guard canEditSettings, let value = failedDesiredValues[id], let record = catalog[id] else { return }
        rowStates[id]?.availability = SystemSettingCompatibilityEvaluator.availability(for: record.definition, environment: environment)
        rowStates[id]?.errorMessage = nil
        apply(value, to: id)
    }

    var canRetryFailedChanges: Bool {
        canEditSettings && lastRollbackResults == nil && !retryableItems.isEmpty
    }

    private var retryableItems: [SystemSettingsProfilePlanItem] {
        let retryKinds: Set<SystemSettingsProfileApplyResultKind> = [
            .failedAndRolledBack, .failedWithoutRollback, .cancelled, .previewChanged,
            .providerUnavailable, .permissionMissing, .hardwareUnavailable, .verificationUnavailable,
        ]
        let ids = Set((lastApplyReport?.results ?? []).filter { retryKinds.contains($0.kind) }.map(\.settingID))
        return (activePlan?.items ?? []).filter { $0.isSelected && ids.contains($0.settingID) }
    }

    func retryFailedChanges() {
        guard canRetryFailedChanges, writeTasks.isEmpty, let plan = activePlan,
              let previousReport = lastApplyReport else { return }
        let profile = SystemSettingsProfile(id: plan.profileID, name: plan.profileName, entries: retryableItems.map {
            .init(settingID: $0.settingID, desiredValue: $0.desiredValue, category: catalog[$0.settingID]?.definition.category)
        })
        preparePlan(for: profile)
        retryBaseReport = previousReport
        lastApplyReport = previousReport
        destination = .profiles
    }

    private func mergedRetryReport(_ attempt: SystemSettingsProfileApplyReport) -> SystemSettingsProfileApplyReport {
        guard let base = retryBaseReport else { return attempt }
        var results = base.results
        for result in attempt.results {
            if let index = results.firstIndex(where: { $0.settingID == result.settingID }) { results[index] = result }
            else { results.append(result) }
        }
        var entries = base.rollbackPoint.entries
        for entry in attempt.rollbackPoint.entries where !entries.contains(where: { $0.settingID == entry.settingID }) {
            entries.append(entry)
        }
        return .init(id: attempt.id, planID: attempt.planID, completedAt: attempt.completedAt, results: results,
                     rollbackPoint: .init(id: base.rollbackPoint.id, createdAt: base.rollbackPoint.createdAt,
                                          profileID: base.rollbackPoint.profileID, entries: entries))
    }

    @discardableResult
    private func persistRecoveries() -> Bool {
        let entries = pendingRecoveries.values.sorted { $0.id.rawValue < $1.id.rawValue }
        guard let data = try? JSONEncoder().encode(entries) else {
            recoveryPersistenceError = MacSettingsStrings.text("Recovery records have not been saved. Do not quit the app.")
            return false
        }
        storage.set(data, forKey: StorageKey.recoveries)
        guard storage.data(forKey: StorageKey.recoveries) == data else {
            recoveryPersistenceError = MacSettingsStrings.text("Recovery records have not been saved. Do not quit the app. Resolve recovery, then retry saving.")
            return false
        }
        recoveryPersistenceError = nil
        return true
    }

    func retrySavingRecoveries() {
        guard canResolveRecovery else { return }
        persistRecoveries()
        onStateChange?()
    }

    private func stageRecovery(for id: SystemSettingID, original: SystemSettingSnapshot, message: String) {
        // Save the recovery target before any further asynchronous observation can stall.
        pendingRecoveries[id] = .init(settingID: id,
            original: pendingRecoveries[id]?.original ?? original, current: nil, message: message)
        rollbackFailureMessages[id] = message
        rowStates[id]?.value = nil
        persistRecoveries()
        onStateChange?()
    }

    private func retainRecovery(record: SystemSettingRecord, original: SystemSettingSnapshot, message: String) async {
        stageRecovery(for: record.id, original: original, message: message)
        let current = try? await record.adapter.snapshot()
        pendingRecoveries[record.id]?.current = current
        rowStates[record.id]?.value = current?.value
        persistRecoveries()
        onStateChange?()
    }

    func retryRecovery(_ id: SystemSettingID) {
        guard let recovery = pendingRecoveries[id], let record = catalog[id],
              beginProfileOperation(settingIDs: [id], state: .restoring, total: 1) else { return }
        let point = SystemSettingRollbackPoint(id: UUID(), createdAt: Date(), profileID: UUID(), entries: [
            .init(settingID: id, value: recovery.original.value, snapshot: recovery.original),
        ])
        profileOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishProfileOperation(settingIDs: [id]) }
            let results = await applyCoordinator.rollback(point) { event in
                receiveRestorationProgress(event, point: point)
            }
            guard let result = results.first else { return }
            if result.kind == .appliedAndVerified {
                pendingRecoveries[id] = nil
                rollbackFailureMessages[id] = nil
                failedSettingIDs.remove(id)
                rowStates[id]?.value = recovery.original.value
                rowStates[id]?.verification = .verified
                rowStates[id]?.errorMessage = nil
                rowStates[id]?.availability = SystemSettingCompatibilityEvaluator.availability(for: record.definition, environment: environment)
                if let index = lastRollbackResults?.firstIndex(where: { $0.settingID == id }) {
                    lastRollbackResults?[index] = result
                }
                persistRecoveries()
            } else if result.kind != .cancelled {
                await retainRecovery(record: record, original: recovery.original, message: result.message ?? recovery.message)
                rowStates[id]?.errorMessage = pendingRecoveries[id]?.message
            }
        }
    }

    func keepCurrentValues(_ id: SystemSettingID) {
        guard isActive, operationState == .idle, writeTasks.isEmpty,
              let recovery = pendingRecoveries.removeValue(forKey: id) else { return }
        guard persistRecoveries() else {
            pendingRecoveries[id] = recovery
            onStateChange?()
            return
        }
        rollbackFailureMessages[id] = nil
        failedSettingIDs.remove(id)
        failedDesiredValues[id] = nil
        rowStates[id]?.errorMessage = nil
        rowStates[id]?.verification = .unverified
        if let index = lastRollbackResults?.firstIndex(where: { $0.settingID == id }), let record = catalog[id] {
            lastRollbackResults?[index] = .init(settingID: id, title: record.definition.title,
                                               kind: .skippedByUser, message: MacSettingsStrings.text("Current values were kept."))
        }
        onStateChange?()
        scheduleExternalRefresh()
    }

    private func canRead(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart, .permissionMissing:
            true
        case .providerUnavailable, .hardwareUnavailable, .guidedManual,
             .managedOnly, .unsupported, .systemVersionUnsupported:
            false
        }
    }

    private func canApply(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart:
            true
        case .providerUnavailable, .hardwareUnavailable, .permissionMissing, .guidedManual,
             .managedOnly, .unsupported, .systemVersionUnsupported:
            false
        }
    }
}
