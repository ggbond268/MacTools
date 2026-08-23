import Foundation

enum PluginDisplaySurface: CaseIterable, Hashable, Sendable {
    case dashboard
    case featurePanel
}

enum PluginSettingsLandingPage: String, Sendable {
    case dashboard
    case featurePanel
    case marketplace
}

@MainActor
final class PluginDisplayPreferencesStore {
    private enum DefaultsKey {
        static let storage = "plugin.display.preferences"
        static let lastPluginSettingsLandingPage = "plugin.settings.lastLandingPage"
    }

    private struct LegacyStoredPreferences: Codable, Equatable {
        var orderedPluginIDs: [String] = []
        var hiddenPluginIDs: Set<String> = []
    }

    private struct LegacyCompatibilityProjection: Decodable {
        var orderedPluginIDs: [String]?
        var hiddenPluginIDs: Set<String>?
    }

    private struct VersionTwoStoredPreferences: Codable, Equatable {
        static let version = 2

        var version: Int = Self.version
        var generalPluginOrder: [String] = []
        var globallyHiddenPluginIDs: Set<String> = []
        var dashboardOrderedPluginIDs: [String] = []
        var featurePanelOrderedPluginIDs: [String] = []
        var isDashboardOrderInitialized = false
        var isFeaturePanelOrderInitialized = false
    }

    /// The first independent-layout format temporarily held legacy-hidden
    /// plugins for a user-facing review. Version four maps those IDs to the
    /// two surface visibility preferences instead.
    private struct VersionThreeStoredPreferences: Codable, Equatable {
        static let version = 3

        var version: Int = Self.version
        var generalPluginOrder: [String] = []
        var dashboardOrderedPluginIDs: [String] = []
        var featurePanelOrderedPluginIDs: [String] = []
        var isDashboardOrderInitialized = false
        var isFeaturePanelOrderInitialized = false
        var pendingLegacyDisabledPluginIDs: Set<String> = []
    }

    private struct StoredPreferences: Codable, Equatable {
        static let currentVersion = 4

        var version = currentVersion
        // Compatibility projection for public releases that only understand
        // the original unversioned layout payload. These fields are refreshed
        // on every write and ignored by current readers.
        var orderedPluginIDs: [String]? = nil
        var hiddenPluginIDs: Set<String>? = nil
        // Retained only to seed separate surface orders for users upgrading
        // from the original shared-order model.
        var generalPluginOrder: [String] = []
        var dashboardOrderedPluginIDs: [String] = []
        var featurePanelOrderedPluginIDs: [String] = []
        var isDashboardOrderInitialized = false
        var isFeaturePanelOrderInitialized = false
        var dashboardHiddenPluginIDs: Set<String> = []
        var featurePanelHiddenPluginIDs: Set<String> = []
        var isDashboardVisibilityInitialized = false
        var isFeaturePanelVisibilityInitialized = false
        // Retained only until each supported surface has migrated the legacy
        // global checkbox into its own show/hide preference.
        var legacyHiddenPluginIDs: Set<String> = []
    }

    private let userDefaults: UserDefaults
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedPreferences: StoredPreferences?
    // True when a passive read came from data this version cannot safely
    // decode. Read-time lazy migrations update only the cache so they do not
    // erase newer schemas. An explicit setter is user intent and deliberately
    // replaces the unreadable payload with this version's schema.
    private var shouldPreserveStoredPayload = false

    /// Runs once after the next complete preferences snapshot is written.
    /// The host uses this to acknowledge an external legacy migration marker
    /// only after the staged state has become durable in this store.
    var onNextSuccessfulPersistence: (() -> Void)?

    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.userDefaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    // MARK: - Plugin settings navigation

    /// This is deliberately kept outside the exportable layout payload. It is
    /// local navigation state, not part of a user's portable configuration.
    func lastPluginSettingsLandingPage() -> PluginSettingsLandingPage? {
        guard let rawValue = userDefaults.string(forKey: DefaultsKey.lastPluginSettingsLandingPage) else {
            return nil
        }

        return PluginSettingsLandingPage(rawValue: rawValue)
    }

    func setLastPluginSettingsLandingPage(_ page: PluginSettingsLandingPage) {
        userDefaults.set(page.rawValue, forKey: DefaultsKey.lastPluginSettingsLandingPage)
    }

    /// Adds IDs that were hidden by the pre-layout-editor global checkbox.
    ///
    /// The host calls this before loading legacy dynamic packages, then each
    /// surface consumes the IDs the first time it has enough capability data
    /// to initialize its own visibility preference. Keeping this small
    /// staging set avoids treating visibility as a plugin lifecycle state.
    /// Returns `true` only when the staged IDs are durably persisted. Callers
    /// must retain their source migration marker when this version deliberately
    /// preserves a newer, unreadable preferences payload.
    @discardableResult
    func addLegacyHiddenPluginIDs(_ pluginIDs: Set<String>) -> Bool {
        guard !pluginIDs.isEmpty else {
            return true
        }

        var preferences = loadPreferences()
        preferences.legacyHiddenPluginIDs.formUnion(pluginIDs)
        if shouldPreserveStoredPayload {
            cachedPreferences = preferences
            return false
        } else {
            return persist(preferences)
        }
    }

    // MARK: - Legacy shared-order compatibility

    func orderedPluginIDs(defaultPluginIDs: [String]) -> [String] {
        normalizedVisibleOrder(
            loadPreferences().generalPluginOrder,
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func setOrderedPluginIDs(
        _ orderedPluginIDs: [String],
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        preferences.generalPluginOrder = mergedStoredOrder(
            requestedOrder: orderedPluginIDs,
            storedOrder: preferences.generalPluginOrder,
            defaultPluginIDs: defaultPluginIDs
        )
        persist(preferences)
    }

    // MARK: - Surface preferences

    /// Returns the saved order for a surface. The first non-empty read lazily
    /// seeds the surface order from the legacy/global order so upgrades
    /// preserve the user's existing layout intent without doing launch-time
    /// migration work before plugin capabilities are available.
    func orderedPluginIDs(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) -> [String] {
        var preferences = loadPreferences()
        initializeSurfacePreferencesIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences
        )

        return normalizedVisibleOrder(
            storedOrder(for: surface, preferences: preferences),
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func visiblePluginIDs(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) -> [String] {
        let orderedPluginIDs = orderedPluginIDs(for: surface, defaultPluginIDs: defaultPluginIDs)
        let hiddenPluginIDs = hiddenPluginIDSet(for: surface, defaultPluginIDs: defaultPluginIDs)
        return orderedPluginIDs.filter { !hiddenPluginIDs.contains($0) }
    }

    func hiddenPluginIDs(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) -> [String] {
        let orderedPluginIDs = orderedPluginIDs(for: surface, defaultPluginIDs: defaultPluginIDs)
        let hiddenPluginIDs = hiddenPluginIDSet(for: surface, defaultPluginIDs: defaultPluginIDs)
        return orderedPluginIDs.filter { hiddenPluginIDs.contains($0) }
    }

    func setOrderedPluginIDs(
        _ orderedPluginIDs: [String],
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        initializeSurfacePreferencesIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )
        let mergedOrder = mergedStoredOrder(
            requestedOrder: orderedPluginIDs,
            storedOrder: storedOrder(for: surface, preferences: preferences),
            defaultPluginIDs: defaultPluginIDs
        )
        setStoredOrder(mergedOrder, for: surface, preferences: &preferences)
        persist(preferences)
    }

    /// Reorders only the visible projection while keeping hidden IDs in their
    /// saved slots. Re-showing a plugin therefore restores it to that slot.
    func setVisiblePluginIDs(
        _ visiblePluginIDs: [String],
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        initializeSurfacePreferencesIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )

        let hiddenPluginIDs = hiddenPluginIDSet(for: surface, preferences: preferences)
        let visibleDefaultPluginIDs = defaultPluginIDs.filter { !hiddenPluginIDs.contains($0) }
        let mergedOrder = mergedStoredOrder(
            requestedOrder: visiblePluginIDs,
            storedOrder: storedOrder(for: surface, preferences: preferences),
            replaceablePluginIDs: Set(visibleDefaultPluginIDs),
            defaultPluginIDs: visibleDefaultPluginIDs
        )
        setStoredOrder(mergedOrder, for: surface, preferences: &preferences)
        persist(preferences)
    }

    func setPluginVisible(
        _ isVisible: Bool,
        pluginID: String,
        on surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        guard defaultPluginIDs.contains(pluginID) else {
            return
        }

        var preferences = loadPreferences()
        initializeSurfacePreferencesIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )

        var hiddenPluginIDs = hiddenPluginIDSet(for: surface, preferences: preferences)
        if isVisible {
            hiddenPluginIDs.remove(pluginID)
        } else {
            hiddenPluginIDs.insert(pluginID)
        }
        setHiddenPluginIDSet(hiddenPluginIDs, for: surface, preferences: &preferences)
        persist(preferences)
    }

    func setHiddenPluginIDs(
        _ hiddenPluginIDs: Set<String>,
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        initializeSurfacePreferencesIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )
        setHiddenPluginIDSet(hiddenPluginIDs, for: surface, preferences: &preferences)
        persist(preferences)
    }

    func resetOrder(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        setOrderedPluginIDs(
            defaultPluginIDs,
            for: surface,
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func removePlugin(_ pluginID: String) {
        var preferences = loadPreferences()
        preferences.generalPluginOrder.removeAll { $0 == pluginID }
        preferences.dashboardOrderedPluginIDs.removeAll { $0 == pluginID }
        preferences.featurePanelOrderedPluginIDs.removeAll { $0 == pluginID }
        preferences.dashboardHiddenPluginIDs.remove(pluginID)
        preferences.featurePanelHiddenPluginIDs.remove(pluginID)
        preferences.legacyHiddenPluginIDs.remove(pluginID)
        persist(preferences)
    }

    func backupSnapshot(
        defaultPluginIDs: [String],
        dashboardDefaultPluginIDs: [String],
        featurePanelDefaultPluginIDs: [String]
    ) -> PluginDisplayPreferencesBackup {
        migrateLegacyHiddenPluginIDs(
            dashboardDefaultPluginIDs: dashboardDefaultPluginIDs,
            featurePanelDefaultPluginIDs: featurePanelDefaultPluginIDs
        )
        let preferences = loadPreferences()

        let dashboardOrderedPluginIDs = normalizedVisibleOrder(
            storedOrder(for: .dashboard, preferences: preferences),
            defaultPluginIDs: dashboardDefaultPluginIDs
        )
        let featurePanelOrderedPluginIDs = normalizedVisibleOrder(
            storedOrder(for: .featurePanel, preferences: preferences),
            defaultPluginIDs: featurePanelDefaultPluginIDs
        )
        let legacyOrderedPluginIDs = normalizedVisibleOrder(
            legacyOrderedPluginIDsProjection(preferences),
            defaultPluginIDs: defaultPluginIDs
        )

        return PluginDisplayPreferencesBackup(
            orderedPluginIDs: legacyOrderedPluginIDs,
            // Older app versions only understand global visibility. A union
            // is a conservative compatibility projection of the independent
            // surface preferences.
            hiddenPluginIDs: Array(
                preferences.dashboardHiddenPluginIDs
                    .union(preferences.featurePanelHiddenPluginIDs)
                    .union(preferences.legacyHiddenPluginIDs)
            ).sorted(),
            dashboardOrderedPluginIDs: dashboardOrderedPluginIDs,
            featurePanelOrderedPluginIDs: featurePanelOrderedPluginIDs,
            dashboardHiddenPluginIDs: Array(
                preferences.dashboardHiddenPluginIDs.union(preferences.legacyHiddenPluginIDs)
            ).sorted(),
            featurePanelHiddenPluginIDs: Array(
                preferences.featurePanelHiddenPluginIDs.union(preferences.legacyHiddenPluginIDs)
            ).sorted()
        )
    }

    // MARK: - Persistence and migration

    /// Maps the legacy global checkbox to every surface a currently available
    /// plugin supports, then retains only IDs that cannot yet be resolved.
    ///
    /// This is intentionally coordinated by the host with both surface
    /// capability lists. A plugin package can be temporarily incompatible or
    /// otherwise unavailable during an upgrade; removing its legacy ID before
    /// it appears in either list would make its former hidden state unrecoverable.
    func migrateLegacyHiddenPluginIDs(
        dashboardDefaultPluginIDs: [String],
        featurePanelDefaultPluginIDs: [String]
    ) {
        guard !dashboardDefaultPluginIDs.isEmpty || !featurePanelDefaultPluginIDs.isEmpty else {
            return
        }

        var preferences = loadPreferences()
        let originalPreferences = preferences
        initializeSurfacePreferencesIfNeeded(
            .dashboard,
            defaultPluginIDs: dashboardDefaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )
        initializeSurfacePreferencesIfNeeded(
            .featurePanel,
            defaultPluginIDs: featurePanelDefaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )

        let legacyHiddenPluginIDs = preferences.legacyHiddenPluginIDs
        let dashboardLegacyHiddenPluginIDs = legacyHiddenPluginIDs.intersection(dashboardDefaultPluginIDs)
        let featurePanelLegacyHiddenPluginIDs = legacyHiddenPluginIDs.intersection(featurePanelDefaultPluginIDs)

        if !dashboardLegacyHiddenPluginIDs.isEmpty {
            preferences.dashboardHiddenPluginIDs.formUnion(dashboardLegacyHiddenPluginIDs)
        }
        if !featurePanelLegacyHiddenPluginIDs.isEmpty {
            preferences.featurePanelHiddenPluginIDs.formUnion(featurePanelLegacyHiddenPluginIDs)
        }

        // Remove only IDs that have actually been mapped to at least one
        // known surface. Unresolved IDs stay staged for a future rebuild when
        // their package becomes loadable again.
        preferences.legacyHiddenPluginIDs.subtract(
            dashboardLegacyHiddenPluginIDs.union(featurePanelLegacyHiddenPluginIDs)
        )

        guard preferences != originalPreferences else {
            return
        }

        if shouldPreserveStoredPayload {
            cachedPreferences = preferences
        } else {
            _ = persist(preferences)
        }
    }

    private func loadPreferences() -> StoredPreferences {
        if let cachedPreferences {
            return cachedPreferences
        }

        guard let data = userDefaults.data(forKey: DefaultsKey.storage) else {
            let preferences = StoredPreferences()
            cachedPreferences = preferences
            shouldPreserveStoredPayload = false
            return preferences
        }

        if let preferences = try? decoder.decode(StoredPreferences.self, from: data),
           preferences.version == StoredPreferences.currentVersion {
            cachedPreferences = preferences
            shouldPreserveStoredPayload = false
            return preferences
        }

        if let versionTwoPreferences = try? decoder.decode(VersionTwoStoredPreferences.self, from: data),
           versionTwoPreferences.version == VersionTwoStoredPreferences.version {
            let migratedPreferences = StoredPreferences(
                generalPluginOrder: deduplicated(versionTwoPreferences.generalPluginOrder),
                dashboardOrderedPluginIDs: deduplicated(versionTwoPreferences.dashboardOrderedPluginIDs),
                featurePanelOrderedPluginIDs: deduplicated(versionTwoPreferences.featurePanelOrderedPluginIDs),
                isDashboardOrderInitialized: versionTwoPreferences.isDashboardOrderInitialized,
                isFeaturePanelOrderInitialized: versionTwoPreferences.isFeaturePanelOrderInitialized,
                legacyHiddenPluginIDs: versionTwoPreferences.globallyHiddenPluginIDs
            )
            persist(migratedPreferences)
            return migratedPreferences
        }

        if let versionThreePreferences = try? decoder.decode(VersionThreeStoredPreferences.self, from: data),
           versionThreePreferences.version == VersionThreeStoredPreferences.version {
            let migratedPreferences = StoredPreferences(
                generalPluginOrder: deduplicated(versionThreePreferences.generalPluginOrder),
                dashboardOrderedPluginIDs: deduplicated(versionThreePreferences.dashboardOrderedPluginIDs),
                featurePanelOrderedPluginIDs: deduplicated(versionThreePreferences.featurePanelOrderedPluginIDs),
                isDashboardOrderInitialized: versionThreePreferences.isDashboardOrderInitialized,
                isFeaturePanelOrderInitialized: versionThreePreferences.isFeaturePanelOrderInitialized,
                legacyHiddenPluginIDs: versionThreePreferences.pendingLegacyDisabledPluginIDs
            )
            persist(migratedPreferences)
            return migratedPreferences
        }

        if !payloadContainsSchemaVersion(data),
           let legacyPreferences = try? decoder.decode(LegacyStoredPreferences.self, from: data) {
            let migratedPreferences = StoredPreferences(
                generalPluginOrder: deduplicated(legacyPreferences.orderedPluginIDs),
                legacyHiddenPluginIDs: legacyPreferences.hiddenPluginIDs
            )
            persist(migratedPreferences)
            return migratedPreferences
        }

        // Preserve unknown or unreadable versioned payloads instead of
        // deleting them. Newer schemas retain these legacy projection fields,
        // so use them for a better read-only fallback while keeping the
        // original payload byte-for-byte until the user explicitly edits it.
        let compatibilityProjection = try? decoder.decode(
            LegacyCompatibilityProjection.self,
            from: data
        )
        let preferences = StoredPreferences(
            generalPluginOrder: deduplicated(compatibilityProjection?.orderedPluginIDs ?? []),
            legacyHiddenPluginIDs: compatibilityProjection?.hiddenPluginIDs ?? []
        )
        cachedPreferences = preferences
        shouldPreserveStoredPayload = true
        return preferences
    }

    private func payloadContainsSchemaVersion(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return false
        }

        return dictionary.keys.contains("version")
    }

    @discardableResult
    private func persist(_ preferences: StoredPreferences) -> Bool {
        var preferences = preferences
        preferences.orderedPluginIDs = legacyOrderedPluginIDsProjection(preferences)
        preferences.hiddenPluginIDs = preferences.dashboardHiddenPluginIDs
            .union(preferences.featurePanelHiddenPluginIDs)
            .union(preferences.legacyHiddenPluginIDs)

        guard let data = try? encoder.encode(preferences) else {
            return false
        }

        let previousPreferences = userDefaults.data(forKey: DefaultsKey.storage).flatMap { data in
            try? decoder.decode(StoredPreferences.self, from: data)
        }
        userDefaults.set(data, forKey: DefaultsKey.storage)
        cachedPreferences = preferences
        shouldPreserveStoredPayload = false
        let completion = onNextSuccessfulPersistence
        onNextSuccessfulPersistence = nil
        completion?()
        if previousPreferences != preferences {
            preferencesBackupChangeReporter?.didPersist(.pluginDisplay)
        }
        return true
    }

    private func legacyOrderedPluginIDsProjection(_ preferences: StoredPreferences) -> [String] {
        deduplicated(
            preferences.generalPluginOrder
                + preferences.dashboardOrderedPluginIDs
                + preferences.featurePanelOrderedPluginIDs
        )
    }

    private func initializeSurfacePreferencesIfNeeded(
        _ surface: PluginDisplaySurface,
        defaultPluginIDs: [String],
        preferences: inout StoredPreferences,
        persistChanges: Bool = true
    ) {
        let isOrderInitialized: Bool
        let isVisibilityInitialized: Bool
        switch surface {
        case .dashboard:
            isOrderInitialized = preferences.isDashboardOrderInitialized
            isVisibilityInitialized = preferences.isDashboardVisibilityInitialized
        case .featurePanel:
            isOrderInitialized = preferences.isFeaturePanelOrderInitialized
            isVisibilityInitialized = preferences.isFeaturePanelVisibilityInitialized
        }

        // Dynamic plugins may intentionally load after the host's first
        // rebuild. An empty list does not contain enough capability data to
        // complete a legacy migration, so defer initialization until it does.
        guard (!isOrderInitialized || !isVisibilityInitialized), !defaultPluginIDs.isEmpty else {
            return
        }

        if !isOrderInitialized {
            let seededOrder = normalizedVisibleOrder(
                preferences.generalPluginOrder,
                defaultPluginIDs: defaultPluginIDs
            )
            setStoredOrder(seededOrder, for: surface, preferences: &preferences)
        }

        if !isVisibilityInitialized {
            setHiddenPluginIDSet(
                preferences.legacyHiddenPluginIDs.intersection(defaultPluginIDs),
                for: surface,
                preferences: &preferences
            )
        }

        switch surface {
        case .dashboard:
            preferences.isDashboardOrderInitialized = true
            preferences.isDashboardVisibilityInitialized = true
        case .featurePanel:
            preferences.isFeaturePanelOrderInitialized = true
            preferences.isFeaturePanelVisibilityInitialized = true
        }

        if persistChanges, shouldPreserveStoredPayload {
            cachedPreferences = preferences
        } else if persistChanges {
            _ = persist(preferences)
        }
    }

    private func hiddenPluginIDSet(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) -> Set<String> {
        var preferences = loadPreferences()
        initializeSurfacePreferencesIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences
        )
        return hiddenPluginIDSet(for: surface, preferences: preferences)
    }

    private func hiddenPluginIDSet(
        for surface: PluginDisplaySurface,
        preferences: StoredPreferences
    ) -> Set<String> {
        switch surface {
        case .dashboard:
            preferences.dashboardHiddenPluginIDs
        case .featurePanel:
            preferences.featurePanelHiddenPluginIDs
        }
    }

    private func setHiddenPluginIDSet(
        _ pluginIDs: Set<String>,
        for surface: PluginDisplaySurface,
        preferences: inout StoredPreferences
    ) {
        switch surface {
        case .dashboard:
            preferences.dashboardHiddenPluginIDs = pluginIDs
        case .featurePanel:
            preferences.featurePanelHiddenPluginIDs = pluginIDs
        }
    }

    private func storedOrder(
        for surface: PluginDisplaySurface,
        preferences: StoredPreferences
    ) -> [String] {
        switch surface {
        case .dashboard:
            return preferences.dashboardOrderedPluginIDs
        case .featurePanel:
            return preferences.featurePanelOrderedPluginIDs
        }
    }

    private func setStoredOrder(
        _ orderedPluginIDs: [String],
        for surface: PluginDisplaySurface,
        preferences: inout StoredPreferences
    ) {
        switch surface {
        case .dashboard:
            preferences.dashboardOrderedPluginIDs = orderedPluginIDs
        case .featurePanel:
            preferences.featurePanelOrderedPluginIDs = orderedPluginIDs
        }
    }

    /// Produces the current view without rewriting storage, so IDs belonging
    /// to temporarily absent plugins remain available for later restoration.
    private func normalizedVisibleOrder(
        _ storedOrder: [String],
        defaultPluginIDs: [String]
    ) -> [String] {
        let validPluginIDs = Set(defaultPluginIDs)
        var seenPluginIDs: Set<String> = []
        var result: [String] = []

        for pluginID in storedOrder where validPluginIDs.contains(pluginID) {
            guard seenPluginIDs.insert(pluginID).inserted else {
                continue
            }

            result.append(pluginID)
        }

        for pluginID in defaultPluginIDs where seenPluginIDs.insert(pluginID).inserted {
            result.append(pluginID)
        }

        return result
    }

    /// Replaces the currently available IDs in their stored slots while
    /// retaining unavailable IDs and their relative positions.
    private func mergedStoredOrder(
        requestedOrder: [String],
        storedOrder: [String],
        replaceablePluginIDs: Set<String>? = nil,
        defaultPluginIDs: [String]
    ) -> [String] {
        let availablePluginIDs = replaceablePluginIDs ?? Set(defaultPluginIDs)
        let normalizedRequestedOrder = normalizedVisibleOrder(
            requestedOrder,
            defaultPluginIDs: defaultPluginIDs
        )
        var requestedIterator = normalizedRequestedOrder.makeIterator()
        var seenPluginIDs: Set<String> = []
        var result: [String] = []

        for storedPluginID in deduplicated(storedOrder) {
            let nextPluginID: String
            if availablePluginIDs.contains(storedPluginID) {
                guard let requestedPluginID = requestedIterator.next() else {
                    continue
                }
                nextPluginID = requestedPluginID
            } else {
                nextPluginID = storedPluginID
            }

            if seenPluginIDs.insert(nextPluginID).inserted {
                result.append(nextPluginID)
            }
        }

        while let requestedPluginID = requestedIterator.next() {
            if seenPluginIDs.insert(requestedPluginID).inserted {
                result.append(requestedPluginID)
            }
        }

        return result
    }

    private func deduplicated(_ pluginIDs: [String]) -> [String] {
        var seenPluginIDs: Set<String> = []
        return pluginIDs.filter { seenPluginIDs.insert($0).inserted }
    }
}
