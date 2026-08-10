import Foundation
import IOKit
import IOKit.ps

/// Reads the current battery snapshot from IOPS + AppleSmartBattery registry.
@MainActor
final class BatteryChargeLimitReader: BatteryChargeLimitReading {

    init() {}

    func readSnapshot() -> BatterySnapshot {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .empty
        }

        var fallback: [String: Any]?
        var battery: [String: Any]?
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            fallback = fallback ?? desc
            if desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                battery = desc
                break
            }
        }

        guard let description = battery ?? fallback else {
            return .empty
        }

        let maxCapacity = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let currentCapacity = min(max(description[kIOPSCurrentCapacityKey] as? Int ?? 0, 0), maxCapacity)
        let levelPercent = Int(round(Double(currentCapacity) / Double(maxCapacity) * 100.0))
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        let powerSource = description[kIOPSPowerSourceStateKey] as? String ?? ""
        let isOnAdapter = powerSource == kIOPSACPowerValue

        let state: BatteryPowerState
        if isCharged || levelPercent >= 100 {
            state = .charged
        } else if isCharging {
            state = .charging
        } else if isOnAdapter {
            state = .acPower
        } else if powerSource == kIOPSBatteryPowerValue {
            state = .unplugged
        } else {
            state = .unknown
        }

        let registry = Self.collectRegistryInfo()

        return BatterySnapshot(
            isAvailable: true,
            levelPercent: levelPercent,
            state: state,
            isOnAdapter: isOnAdapter,
            temperatureCelsius: registry.temperatureCelsius,
            healthPercent: registry.healthPercent,
            cycleCount: registry.cycleCount
        )
    }

    private static func collectRegistryInfo() -> (
        temperatureCelsius: Double?,
        healthPercent: Int?,
        cycleCount: Int?
    ) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return (nil, nil, nil)
        }
        defer { IOObjectRelease(service) }

        let temperature = registryInt(service, "Temperature").map { Double($0) / 100.0 }
        let design = registryInt(service, "DesignCapacity")
        let nominal = registryInt(service, "NominalChargeCapacity")
        let rawMax = registryInt(service, "AppleRawMaxCapacity")
        let health: Int?
        if let design, design > 0 {
            let currentMax = nominal ?? rawMax
            if let currentMax, currentMax > 0 {
                health = min(100, Int(round(Double(currentMax) / Double(design) * 100.0)))
            } else {
                health = nil
            }
        } else {
            health = nil
        }

        return (temperature, health, registryInt(service, "CycleCount"))
    }

    private static func registryInt(_ service: io_registry_entry_t, _ key: String) -> Int? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
