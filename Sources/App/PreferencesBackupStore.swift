import Foundation
import MacToolsPluginKit

@MainActor
final class PreferencesBackupStore: PreferencesBackupApplicationStoring {
    private let userDefaults: UserDefaults
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?

    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.userDefaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences {
        let sidebarSortMode = SettingsSidebarPreferencesStore.storedSortMode(in: userDefaults)
        return PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.stored(in: userDefaults).rawValue,
            floatingPanelAppearance: PluginFloatingPanelAppearance.stored(in: userDefaults).rawValue,
            languagePreference: AppLanguagePreference.stored(in: userDefaults).rawValue,
            settingsSidebarPluginSortMode: sidebarSortMode.rawValue,
            settingsSidebarCustomPluginOrder:
                SettingsSidebarPreferencesStore.storedCustomOrderIfInitialized(in: userDefaults)
        )
    }

    func validates(_ preferences: PreferencesBackup.ApplicationPreferences) -> Bool {
        guard AppAppearancePreference(rawValue: preferences.appearancePreference) != nil,
              AppLanguagePreference(rawValue: preferences.languagePreference) != nil
        else {
            return false
        }
        if let rawValue = preferences.floatingPanelAppearance,
           PluginFloatingPanelAppearance(rawValue: rawValue) == nil {
            return false
        }

        switch (
            preferences.settingsSidebarPluginSortMode,
            preferences.settingsSidebarCustomPluginOrder
        ) {
        case (nil, nil):
            return true
        case let (rawSortMode?, customOrder):
            guard SettingsSidebarPluginSortMode(rawValue: rawSortMode) != nil else {
                return false
            }
            guard let customOrder else {
                return true
            }
            return customOrder.allSatisfy { !$0.isEmpty }
                && Set(customOrder).count == customOrder.count
        case (nil, _?):
            return false
        }
    }

    func apply(_ preferences: PreferencesBackup.ApplicationPreferences) {
        guard let appearance = AppAppearancePreference(rawValue: preferences.appearancePreference),
              let language = AppLanguagePreference(rawValue: preferences.languagePreference)
        else {
            return
        }

        let previousPreferences = applicationPreferences()
        appearance.storeAndApply(in: userDefaults)
        let floatingPanelAppearance = preferences.floatingPanelAppearance
            .flatMap { PluginFloatingPanelAppearance(rawValue: $0) } ?? .system
        floatingPanelAppearance.store(in: userDefaults)
        language.store(in: userDefaults)

        if let rawSortMode = preferences.settingsSidebarPluginSortMode,
           let sortMode = SettingsSidebarPluginSortMode(rawValue: rawSortMode) {
            SettingsSidebarPreferencesStore.applyImportedPreferences(
                sortMode: sortMode,
                customOrderedPluginIDs: preferences.settingsSidebarCustomPluginOrder,
                to: userDefaults
            )
        }
        if applicationPreferences() != previousPreferences {
            preferencesBackupChangeReporter?.didPersist(.application)
        }
    }

    func setAppearancePreference(rawValue: String) -> Bool {
        guard let preference = AppAppearancePreference(rawValue: rawValue) else { return false }
        let changed = AppAppearancePreference.stored(in: userDefaults) != preference
        preference.storeAndApply(in: userDefaults)
        guard AppAppearancePreference.stored(in: userDefaults) == preference else { return false }
        if changed {
            preferencesBackupChangeReporter?.didPersist(.application)
        }
        return true
    }

    func setFloatingPanelAppearance(rawValue: String) -> Bool {
        guard let preference = PluginFloatingPanelAppearance(rawValue: rawValue) else { return false }
        let changed = PluginFloatingPanelAppearance.stored(in: userDefaults) != preference
        preference.store(in: userDefaults)
        guard PluginFloatingPanelAppearance.stored(in: userDefaults) == preference else { return false }
        if changed {
            preferencesBackupChangeReporter?.didPersist(.application)
        }
        return true
    }

    func setLanguagePreference(rawValue: String) -> Bool {
        guard let preference = AppLanguagePreference(rawValue: rawValue) else { return false }
        let changed = AppLanguagePreference.stored(in: userDefaults) != preference
        preference.store(in: userDefaults)
        guard AppLanguagePreference.stored(in: userDefaults) == preference else { return false }
        if changed {
            preferencesBackupChangeReporter?.didPersist(.application)
        }
        return true
    }
}
