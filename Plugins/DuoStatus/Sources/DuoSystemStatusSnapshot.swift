import Foundation

// The battery power/Low Power Mode flags, the precise Wi-Fi states, and the
// volume status are adapted from Status Trio
// (https://github.com/lingyired/status-trio, Apache-2.0).

struct DuoSystemStatusSnapshot: Equatable, Sendable {
    enum Battery: Equatable, Sendable {
        case unavailable
        case notPresent
        case level(
            fraction: Double,
            isCharging: Bool,
            isExternalPowerConnected: Bool = false,
            isLowPowerMode: Bool = false
        )

        /// False on desktop Macs and whenever IOKit reports no usable capacity.
        var isPresent: Bool {
            if case .level = self { return true }
            return false
        }

        var fraction: Double? {
            guard case let .level(fraction, _, _, _) = self, fraction.isFinite else { return nil }
            return fraction
        }

        /// A missing battery reports a full charge so desktop Macs keep a stable icon.
        var percentage: Int {
            guard let fraction else { return 100 }
            return Int((min(1, max(0, fraction)) * 100).rounded())
        }

        var isCharging: Bool {
            guard case let .level(_, isCharging, _, _) = self else { return false }
            return isCharging
        }

        /// Active charging implies a power source even when IOKit omits the AC state.
        var isConnectedToPower: Bool {
            guard case let .level(_, isCharging, isExternalPowerConnected, _) = self else { return false }
            return isExternalPowerConnected || isCharging
        }

        /// Only a present battery carries the flag; a Mac without one never shows
        /// the Low Power Mode colour.
        var isLowPowerMode: Bool {
            guard case let .level(_, _, _, isLowPowerMode) = self else { return false }
            return isLowPowerMode
        }
    }

    /// The precise states are always classified, whether or not the user asked to
    /// distinguish them; the renderer collapses them to the plain fan when the
    /// matching option is off.
    enum WiFi: Equatable, Sendable {
        case unavailable
        case off
        case disconnected
        case connected(level: Int)
        case noInternet
        case hotspot
        case temporary
        case shared
    }

    enum Network: Equatable, Sendable {
        case unknown
        case connected
        case disconnected
        case requiresConnection
    }

    enum ConnectionKind: Equatable, Sendable {
        case wifi
        case ethernet
        case other
    }

    struct Volume: Equatable, Sendable {
        /// 0...1 for the default output device; nil when no output device exposes a volume.
        var scalar: Double?
        var isMuted: Bool
        /// True when the default output device uses a Bluetooth transport.
        var isBluetoothOutput: Bool

        init(scalar: Double? = nil, isMuted: Bool = false, isBluetoothOutput: Bool = false) {
            self.scalar = scalar
            self.isMuted = isMuted
            self.isBluetoothOutput = isBluetoothOutput
        }

        static let unknown = Volume()
    }

    var battery: Battery = .unavailable
    var wifi: WiFi = .unavailable
    /// 0...4 signal strength that survives the precise Wi-Fi states, so the
    /// bottom dots keep working while a hotspot or captive network is reported.
    var wifiSignalLevel: Int = 0
    var network: Network = .unknown
    var connectionKind: ConnectionKind?
    var volume: Volume = .unknown

    static let unknown = DuoSystemStatusSnapshot()

    var batteryFraction: Double? { battery.fraction }

    var isCharging: Bool { battery.isCharging }

    var isExternalPowerConnected: Bool { battery.isConnectedToPower }

    /// Lit Wi-Fi dots, 0...4, for every associated state.
    var wifiLevel: Int {
        if case let .connected(level) = wifi { return min(4, max(0, level)) }
        return min(4, max(0, wifiSignalLevel))
    }
}
