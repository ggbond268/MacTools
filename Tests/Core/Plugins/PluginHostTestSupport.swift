import Foundation
import MacToolsPluginKit
@testable import MacTools

@MainActor
func makePluginHostForTests(
    plugins: [any MacToolsPlugin],
    suiteName: String = "PluginHostTestSupport-\(UUID().uuidString)",
    dynamicPluginManager: DynamicPluginManager? = nil,
    loadDynamicPluginsOnInit: Bool = true,
    globalShortcutManager: GlobalShortcutManager? = nil,
    focusedApplicationTargetProvider: (any FocusedApplicationTargetProviding)? = nil
) -> PluginHost {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    return PluginHost(
        plugins: plugins,
        dynamicPluginManager: dynamicPluginManager,
        shortcutStore: ShortcutStore(userDefaults: defaults),
        pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
        preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
        globalShortcutManager: globalShortcutManager ?? GlobalShortcutManager(),
        focusedApplicationTargetProvider: focusedApplicationTargetProvider,
        loadDynamicPluginsOnInit: loadDynamicPluginsOnInit
    )
}
