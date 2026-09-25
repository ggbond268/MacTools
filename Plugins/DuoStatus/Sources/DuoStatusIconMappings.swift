import Foundation

// Adapted from Status Trio (https://github.com/lingyired/status-trio, Apache-2.0).

/// Which colour the battery ring uses. `foreground` keeps the image a template
/// image so the menu bar can tint it.
enum DuoStatusBatteryColorRole: Equatable, Sendable {
    case foreground
    case critical
    case lowPower
    case charging
}

/// What fills the battery ring's top gap.
enum DuoStatusBatteryGapContent: Equatable, Sendable {
    /// Charging: the lightning bolt.
    case bolt
    /// Connected to power without charging: the plug.
    case plug
    /// The percentage numerals.
    case percentage
    /// Nothing: the ring closes into a full arc.
    case empty
}

/// Pure snapshot-to-glyph decisions shared by the renderer and its tests.
enum DuoStatusIconMappings {
    /// Number of lit volume dots, 0...4. A missing output device counts as silent,
    /// and muted output draws four unlit dots rather than a separate mute glyph.
    static func volumeSteps(scalar: Double?, isMuted: Bool) -> Int {
        guard let scalar, scalar.isFinite else { return 0 }
        let clamped = min(1, max(0, scalar))
        if isMuted || clamped == 0 { return 0 }
        if clamped <= 0.25 { return 1 }
        if clamped <= 0.50 { return 2 }
        if clamped <= 0.75 { return 3 }
        return 4
    }

    /// Filled share of the volume bar, 0...1. Missing, muted, and non-finite
    /// readings leave only the track, matching four unlit dots.
    static func volumeBarFraction(scalar: Double?, isMuted: Bool) -> Double {
        guard !isMuted, let scalar, scalar.isFinite else { return 0 }
        return min(1, max(0, scalar))
    }

    /// Whether the bottom of the ring draws the continuous volume bar instead of dots.
    static func usesVolumeBar(options: DuoStatusIconOptions) -> Bool {
        options.bottomIndicator == .volume && options.volumeStyle == .bar
    }

    /// First match wins: a critically low level outranks charging, so a Mac
    /// charging at a very low level still shows the warning colour.
    ///
    /// Two details deliberately keep the shipping icon unchanged: the threshold
    /// compares the unrounded level (19.6% is still below 20%), and only active
    /// charging turns green — a Mac held on power without charging, such as at
    /// an Optimized Battery Charging limit, keeps a monochrome ring.
    static func batteryColorRole(
        _ battery: DuoSystemStatusSnapshot.Battery,
        options: DuoStatusIconOptions
    ) -> DuoStatusBatteryColorRole {
        guard options.usesBatteryStatusColors else { return .foreground }
        let threshold = Double(min(100, max(0, options.batteryCriticalThreshold)))
        if let fraction = battery.fraction, min(1, max(0, fraction)) * 100 < threshold { return .critical }
        if battery.isLowPowerMode { return .lowPower }
        if battery.isCharging { return .charging }
        return .foreground
    }

    /// A charging battery keeps the bolt. A connected power source that is not
    /// charging, including a battery that is already full, shows the plug, or
    /// the percentage when the user asked for the number in that state.
    static func batteryGapContent(
        _ battery: DuoSystemStatusSnapshot.Battery,
        options: DuoStatusIconOptions
    ) -> DuoStatusBatteryGapContent {
        if battery.isPresent, options.showsChargingIndicator {
            if battery.isCharging { return .bolt }
            let showsPercentageForPower = options.showsPercentageWhenConnected
                && options.showsBatteryPercentage
            if battery.isConnectedToPower, !showsPercentageForPower {
                return .plug
            }
        }

        return options.showsBatteryPercentage ? .percentage : .empty
    }

    /// Whether the Bluetooth audio glyph takes over the centre of the ring.
    static func shouldUseBluetoothGlyph(
        volume: DuoSystemStatusSnapshot.Volume,
        wifi: DuoSystemStatusSnapshot.WiFi,
        network: DuoSystemStatusSnapshot.Network,
        options: DuoStatusIconOptions
    ) -> Bool {
        guard options.showsBluetoothAudioGlyph, volume.isBluetoothOutput else { return false }
        guard options.bluetoothGlyphPrioritizesNetworkErrors else { return true }

        // A wired connection is not a Wi-Fi error and can still coexist with
        // Bluetooth audio, but being offline is always worth showing.
        if network.isOffline { return false }
        return !wifi.isNetworkErrorState
    }

    /// Lit dots at the bottom of the ring, 0...4. Only the source changes with
    /// the selected indicator; the artwork is identical.
    static func bottomIndicatorSteps(
        snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions
    ) -> Int {
        switch options.bottomIndicator {
        case .wifi:
            snapshot.wifiLevel
        case .volume:
            volumeSteps(scalar: snapshot.volume.scalar, isMuted: snapshot.volume.isMuted)
        }
    }
}

extension DuoSystemStatusSnapshot.WiFi {
    /// States where showing the network problem matters more than the Bluetooth glyph.
    var isNetworkErrorState: Bool {
        switch self {
        case .disconnected, .noInternet, .off, .unavailable:
            true
        case .connected, .hotspot, .temporary, .shared:
            false
        }
    }
}

extension DuoSystemStatusSnapshot.Network {
    /// `unknown` means no path update has arrived yet, which is not a failure.
    var isOffline: Bool {
        switch self {
        case .disconnected, .requiresConnection:
            true
        case .connected, .unknown:
            false
        }
    }
}
