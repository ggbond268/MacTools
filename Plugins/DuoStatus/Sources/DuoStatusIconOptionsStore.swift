import Foundation
import MacToolsPluginKit

// Adapted from Status Trio (https://github.com/lingyired/status-trio, Apache-2.0).

/// Persists `DuoStatusIconOptions` through the plugin's scoped storage.
/// Keys are stable and must not be renamed without a migration.
@MainActor
struct DuoStatusIconOptionsStore {
    enum Key {
        static let iconSize = "icon-size"
        static let bottomIndicator = "bottom-indicator"
        static let volumeStyle = "volume-style"
        static let showsBatteryPercentage = "shows-battery-percentage"
        static let showsPercentageWhenConnected = "shows-percentage-when-connected"
        static let showsChargingIndicator = "shows-charging-indicator"
        static let usesBatteryStatusColors = "uses-battery-status-colors"
        static let batteryCriticalThreshold = "battery-critical-threshold"
        static let distinguishesNoInternet = "distinguishes-no-internet"
        static let distinguishesHotspot = "distinguishes-hotspot"
        static let distinguishesTemporaryNetwork = "distinguishes-temporary-network"
        static let distinguishesInternetSharing = "distinguishes-internet-sharing"
        static let showsBluetoothAudioGlyph = "shows-bluetooth-audio-glyph"
        static let bluetoothGlyphPrioritizesNetworkErrors = "bluetooth-glyph-prioritizes-network-errors"
    }

    static let criticalThresholdRange = 5...50
    static let criticalThresholdStep = 5

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
    }

    /// A missing key keeps the default, so an option the user never touched
    /// always resolves to the shipping behaviour.
    func load() -> DuoStatusIconOptions {
        var options = DuoStatusIconOptions.default
        if let raw = storage.string(forKey: Key.iconSize),
           let size = DuoStatusIconSize(rawValue: raw) {
            options.iconSize = size
        }
        if let raw = storage.string(forKey: Key.bottomIndicator),
           let indicator = DuoStatusBottomIndicator(rawValue: raw) {
            options.bottomIndicator = indicator
        }
        if let raw = storage.string(forKey: Key.volumeStyle),
           let style = DuoStatusVolumeStyle(rawValue: raw) {
            options.volumeStyle = style
        }
        options.showsBatteryPercentage = bool(
            Key.showsBatteryPercentage, default: options.showsBatteryPercentage
        )
        options.showsPercentageWhenConnected = bool(
            Key.showsPercentageWhenConnected, default: options.showsPercentageWhenConnected
        )
        options.showsChargingIndicator = bool(
            Key.showsChargingIndicator, default: options.showsChargingIndicator
        )
        options.usesBatteryStatusColors = bool(
            Key.usesBatteryStatusColors, default: options.usesBatteryStatusColors
        )
        if let threshold = storage.object(forKey: Key.batteryCriticalThreshold) as? Int {
            options.batteryCriticalThreshold = Self.clampedThreshold(threshold)
        }
        options.distinguishesNoInternet = bool(
            Key.distinguishesNoInternet, default: options.distinguishesNoInternet
        )
        options.distinguishesHotspot = bool(
            Key.distinguishesHotspot, default: options.distinguishesHotspot
        )
        options.distinguishesTemporaryNetwork = bool(
            Key.distinguishesTemporaryNetwork, default: options.distinguishesTemporaryNetwork
        )
        options.distinguishesInternetSharing = bool(
            Key.distinguishesInternetSharing, default: options.distinguishesInternetSharing
        )
        options.showsBluetoothAudioGlyph = bool(
            Key.showsBluetoothAudioGlyph, default: options.showsBluetoothAudioGlyph
        )
        options.bluetoothGlyphPrioritizesNetworkErrors = bool(
            Key.bluetoothGlyphPrioritizesNetworkErrors,
            default: options.bluetoothGlyphPrioritizesNetworkErrors
        )
        return options
    }

    func save(_ options: DuoStatusIconOptions) {
        storage.set(options.iconSize.rawValue, forKey: Key.iconSize)
        storage.set(options.bottomIndicator.rawValue, forKey: Key.bottomIndicator)
        storage.set(options.volumeStyle.rawValue, forKey: Key.volumeStyle)
        storage.set(options.showsBatteryPercentage, forKey: Key.showsBatteryPercentage)
        storage.set(options.showsPercentageWhenConnected, forKey: Key.showsPercentageWhenConnected)
        storage.set(options.showsChargingIndicator, forKey: Key.showsChargingIndicator)
        storage.set(options.usesBatteryStatusColors, forKey: Key.usesBatteryStatusColors)
        storage.set(
            Self.clampedThreshold(options.batteryCriticalThreshold),
            forKey: Key.batteryCriticalThreshold
        )
        storage.set(options.distinguishesNoInternet, forKey: Key.distinguishesNoInternet)
        storage.set(options.distinguishesHotspot, forKey: Key.distinguishesHotspot)
        storage.set(options.distinguishesTemporaryNetwork, forKey: Key.distinguishesTemporaryNetwork)
        storage.set(options.distinguishesInternetSharing, forKey: Key.distinguishesInternetSharing)
        storage.set(options.showsBluetoothAudioGlyph, forKey: Key.showsBluetoothAudioGlyph)
        storage.set(
            options.bluetoothGlyphPrioritizesNetworkErrors,
            forKey: Key.bluetoothGlyphPrioritizesNetworkErrors
        )
    }

    /// Snaps to the slider's step and clamps to its range so a stored value from
    /// another build can never drive the warning colour outside the shown range.
    static func clampedThreshold(_ value: Int) -> Int {
        let step = criticalThresholdStep
        let snapped = Int((Double(value) / Double(step)).rounded()) * step
        return min(criticalThresholdRange.upperBound, max(criticalThresholdRange.lowerBound, snapped))
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        storage.object(forKey: key) as? Bool ?? defaultValue
    }
}
