import Foundation
import MacToolsPluginKit

enum AppL10n {
    static func string(
        _ key: String,
        defaultValue: String,
        table: String = "Localizable",
        bundle: Bundle = .main
    ) -> String {
        PluginRuntimeLocalization.string(
            key,
            defaultValue: defaultValue,
            table: table,
            bundle: bundle
        )
    }

    static func settings(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "Settings")
    }

    static func plugins(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "Plugins")
    }

    static func search(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "Search")
    }

    static func preferencesBackup(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "PreferencesBackup")
    }

    static func feature(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "FeatureUI")
    }

    static func settingsFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: settings(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func pluginsFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: plugins(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func searchFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: search(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func searchPluralFormat(
        _ key: String,
        defaultValue: String,
        count: Int
    ) -> String {
        String(
            format: search(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: [count]
        )
    }

    static func preferencesBackupFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: preferencesBackup(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func preferencesBackupPluralFormat(
        _ key: String,
        defaultValue: String,
        count: Int,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: preferencesBackup(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: [count as CVarArg] + arguments
        )
    }
}

/// Localization for the Actions, Run Links, and Automation surfaces.
///
/// These newer surfaces use their Simplified Chinese source copy as the stable
/// String Catalog key. Keeping lookup and formatting here makes runtime language
/// switching behave the same way as the rest of Settings while also giving the
/// localization audit one consistent call site to discover.
enum FeatureL10n {
    static func string(_ source: String) -> String {
        AppL10n.feature(source, defaultValue: source)
    }

    static func format(_ source: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(source),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func joined(_ values: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }
}
