import Foundation
import MacToolsPluginKit

private final class MacSettingsResourceToken {}

/// The static plugin core is linked into its resource-bearing dynamic bundle.
/// Resolve each lookup against the host's current language, with English fallback.
enum MacSettingsStrings {
    static let resourceBundle = Bundle(for: MacSettingsResourceToken.self)
    @TaskLocal static var bundleOverride: Bundle?

    static func text(_ english: String) -> String {
        PluginRuntimeLocalization.string(english, defaultValue: english, table: "MacSettings",
                                         bundle: bundleOverride ?? resourceBundle)
    }

    static func format(_ english: String, _ arguments: CVarArg...) -> String {
        String(format: text(english), locale: PluginRuntimeLocalization.locale, arguments: arguments)
    }

    static func searchAliases(for english: String) -> [String] {
        let bundle = bundleOverride ?? resourceBundle
        guard let path = bundle.path(forResource: "zh-Hans", ofType: "lproj"),
              let chinese = Bundle(path: path) else { return [english] }
        return [english, chinese.localizedString(forKey: english, value: english, table: "MacSettings")]
    }
}

/// Store the source key, not the translated value, in long-lived catalog models.
/// User-entered names, paths, setting IDs, and stored values never use this wrapper.
@propertyWrapper
struct MacSettingsLocalized: Codable, Equatable, Hashable, Sendable {
    private let source: String
    init(wrappedValue: String) { source = wrappedValue }
    var wrappedValue: String { MacSettingsStrings.text(source) }
    var projectedValue: String { source }

    init(from decoder: Decoder) throws {
        source = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(source)
    }
}
