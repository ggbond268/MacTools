import Foundation

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
            languagePreference: AppLanguagePreference.stored(in: userDefaults).rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.current(userDefaults).rawValue,
            settingsSidebarPluginSortMode: sidebarSortMode.rawValue,
            settingsSidebarCustomPluginOrder:
                SettingsSidebarPreferencesStore.storedCustomOrderIfInitialized(in: userDefaults)
        )
    }

    func validates(_ preferences: PreferencesBackup.ApplicationPreferences) -> Bool {
        guard AppAppearancePreference(rawValue: preferences.appearancePreference) != nil
            && AppLanguagePreference(rawValue: preferences.languagePreference) != nil
            && MenuBarClickBehaviorPreference(rawValue: preferences.menuBarClickBehavior) != nil
        else {
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
              let language = AppLanguagePreference(rawValue: preferences.languagePreference),
              let clickBehavior = MenuBarClickBehaviorPreference(rawValue: preferences.menuBarClickBehavior)
        else {
            return
        }

        let previousPreferences = applicationPreferences()
        appearance.storeAndApply(in: userDefaults)
        language.store(in: userDefaults)
        userDefaults.set(clickBehavior.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)

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

    func setMenuBarClickBehavior(rawValue: String) -> Bool {
        guard let preference = MenuBarClickBehaviorPreference(rawValue: rawValue) else {
            return false
        }
        let changed = MenuBarClickBehaviorPreference.current(userDefaults) != preference
        userDefaults.set(preference.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
        guard MenuBarClickBehaviorPreference.current(userDefaults) == preference else {
            return false
        }
        if changed {
            preferencesBackupChangeReporter?.didPersist(.application)
        }
        return true
    }
}
