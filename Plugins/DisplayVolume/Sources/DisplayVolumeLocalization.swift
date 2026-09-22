import Foundation
import MacToolsPluginKit

private final class DisplayVolumeBundleToken {}

enum DisplayVolumeLocalization {
    static let fallback = PluginLocalization(bundle: Bundle(for: DisplayVolumeBundleToken.self))

    static func string(_ key: String, defaultValue: String) -> String {
        fallback.string(key, defaultValue: defaultValue)
    }

    static func format(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }
}
