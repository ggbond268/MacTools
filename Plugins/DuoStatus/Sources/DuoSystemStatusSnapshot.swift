import Foundation

struct DuoSystemStatusSnapshot: Equatable, Sendable {
    enum Battery: Equatable, Sendable {
        case unavailable
        case notPresent
        case level(fraction: Double, isCharging: Bool, isExternalPowerConnected: Bool = false)
    }

    enum WiFi: Equatable, Sendable {
        case unavailable
        case off
        case disconnected
        case connected(level: Int)
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

    var battery: Battery = .unavailable
    var wifi: WiFi = .unavailable
    var network: Network = .unknown
    var connectionKind: ConnectionKind?

    static let unknown = DuoSystemStatusSnapshot()

    var batteryFraction: Double? {
        guard case let .level(fraction, _, _) = battery else { return nil }
        return fraction
    }

    var isCharging: Bool {
        guard case let .level(_, isCharging, _) = battery else { return false }
        return isCharging
    }

    var isExternalPowerConnected: Bool {
        guard case let .level(_, isCharging, isExternalPowerConnected) = battery else { return false }
        return isExternalPowerConnected || isCharging
    }
}
