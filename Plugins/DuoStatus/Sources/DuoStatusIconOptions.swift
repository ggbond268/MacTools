import Foundation

// Adapted from Status Trio (https://github.com/lingyired/status-trio, Apache-2.0).

/// Overall artwork size inside the fixed 24-point menu-bar canvas.
enum DuoStatusIconSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    var artworkScale: CGFloat {
        switch self {
        case .small: 0.80
        case .medium: 0.88
        // Safe ceiling: the charging bolt tops out at y 18.12 in artwork space.
        case .large: 0.96
        }
    }
}

/// What the four dots at the bottom of the ring represent.
enum DuoStatusBottomIndicator: String, CaseIterable, Sendable {
    /// Wi-Fi signal strength, the shipping behaviour.
    case wifi
    /// Output volume of the default audio device.
    case volume
}

/// How output volume is drawn at the bottom of the ring. Wi-Fi signal always
/// uses the dots, because it only ever has four steps.
enum DuoStatusVolumeStyle: String, CaseIterable, Sendable {
    /// Four dots, one per quarter of the volume range.
    case dots
    /// A continuous bar along the ring's bottom gap.
    case bar
}

/// Everything the renderer needs besides the live snapshot. Persisted by the plugin.
///
/// Every option that changes the shipping artwork defaults to off, so an existing
/// menu bar looks unchanged after an update.
struct DuoStatusIconOptions: Equatable, Sendable {
    static let defaultCriticalThreshold = 20

    var iconSize: DuoStatusIconSize = .small
    var bottomIndicator: DuoStatusBottomIndicator = .wifi
    var volumeStyle: DuoStatusVolumeStyle = .dots
    var showsBatteryPercentage = false
    var showsPercentageWhenConnected = false
    var showsChargingIndicator = true
    var usesBatteryStatusColors = true
    var batteryCriticalThreshold = defaultCriticalThreshold
    var distinguishesNoInternet = false
    var distinguishesHotspot = false
    var distinguishesTemporaryNetwork = false
    var distinguishesInternetSharing = false
    var showsBluetoothAudioGlyph = false
    var bluetoothGlyphPrioritizesNetworkErrors = true

    static let `default` = DuoStatusIconOptions()

    var artworkScale: CGFloat { iconSize.artworkScale }
}
