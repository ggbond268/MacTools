import CoreWLAN
import Foundation
import IOKit.ps

struct DuoLocalSystemStatus: Equatable, Sendable {
    var battery: DuoSystemStatusSnapshot.Battery
    var wifi: DuoSystemStatusSnapshot.WiFi
}

enum DuoSystemStatusReader {
    static func read() -> DuoLocalSystemStatus {
        DuoLocalSystemStatus(battery: readBattery(), wifi: readWiFi())
    }

    static func battery(
        from descriptions: [[String: Any]]?
    ) -> DuoSystemStatusSnapshot.Battery {
        guard let descriptions else { return .unavailable }
        guard let battery = descriptions.first(where: {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && $0[kIOPSIsPresentKey] as? Bool != false
        }) else {
            return .notPresent
        }
        guard let current = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
              current.isFinite, maximum.isFinite, maximum > 0, current >= 0 else {
            return .unavailable
        }
        return .level(
            fraction: min(current / maximum, 1),
            isCharging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            isExternalPowerConnected: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        )
    }

    static func wifi(
        isPowered: Bool,
        isAssociated: Bool,
        rssi: Int
    ) -> DuoSystemStatusSnapshot.WiFi {
        guard isPowered else { return .off }
        guard isAssociated else { return .disconnected }
        // CoreWLAN reports zero when RSSI is unavailable. It is not a strong signal.
        guard rssi < 0, rssi >= -127 else { return .unavailable }
        let level: Int = switch rssi {
        case (-55)...: 4
        case (-65)...: 3
        case (-75)...: 2
        case (-85)...: 1
        default: 0
        }
        return .connected(level: level)
    }

    private static func readBattery() -> DuoSystemStatusSnapshot.Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unavailable
        }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        guard descriptions.count == sources.count else { return .unavailable }
        return battery(from: descriptions)
    }

    private static func readWiFi() -> DuoSystemStatusSnapshot.WiFi {
        guard let interface = CWWiFiClient.shared().interface() else { return .unavailable }
        return wifi(
            isPowered: interface.powerOn(),
            // Association mode remains available without requesting location access for an SSID.
            isAssociated: interface.interfaceMode() != .none,
            rssi: interface.rssiValue()
        )
    }
}
