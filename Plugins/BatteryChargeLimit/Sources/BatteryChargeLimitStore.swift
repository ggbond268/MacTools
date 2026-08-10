import Foundation
import MacToolsPluginKit

/// Persists user-controlled state for the battery charge-limit plugin.
@MainActor
final class BatteryChargeLimitStore: ObservableObject {
    private enum Key {
        static let isEnabled = "is-enabled"
        static let limitPercent = "limit-percent"
        static let mode = "mode"
        static let floorPercent = "floor-percent"
        static let floorReminderEnabled = "floor-reminder-enabled"
        static let thermalProtectionEnabled = "thermal-protection-enabled"
        static let thermalThresholdCelsius = "thermal-threshold-celsius"
        static let thermalMuteDay = "thermal-mute-day"
        static let inhibitChargingDuringSleep = "inhibit-charging-during-sleep"
    }

    private let storage: PluginStorage

    @Published private(set) var isEnabled: Bool
    @Published private(set) var limitPercent: Int
    @Published private(set) var mode: BatteryChargeMode
    @Published private(set) var floorPercent: Int
    @Published private(set) var floorReminderEnabled: Bool
    @Published private(set) var thermalProtectionEnabled: Bool
    @Published private(set) var thermalThresholdCelsius: Int
    @Published private(set) var inhibitChargingDuringSleep: Bool

    init(storage: PluginStorage) {
        self.storage = storage

        let storedIsEnabled = storage.object(forKey: Key.isEnabled) as? Bool
        self.isEnabled = storedIsEnabled ?? false

        let storedLimit = storage.object(forKey: Key.limitPercent) as? Int
        let initial = storedLimit ?? BatteryChargeLimits.defaultPercent
        self.limitPercent = Self.clampLimit(initial)

        if let raw = storage.string(forKey: Key.mode),
           let parsed = BatteryChargeMode(rawValue: raw) {
            self.mode = parsed
        } else {
            self.mode = .holdAtLimit
        }

        let storedFloor = storage.object(forKey: Key.floorPercent) as? Int
        self.floorPercent = Self.clampFloor(storedFloor ?? BatteryChargeLimits.defaultFloorPercent)

        self.floorReminderEnabled = storage.object(forKey: Key.floorReminderEnabled) as? Bool ?? true
        self.thermalProtectionEnabled = storage.object(forKey: Key.thermalProtectionEnabled) as? Bool ?? false
        let storedThermal = storage.object(forKey: Key.thermalThresholdCelsius) as? Int
        self.thermalThresholdCelsius = Self.clampThermal(
            storedThermal ?? BatteryChargeLimits.defaultThermalThresholdCelsius
        )
        self.inhibitChargingDuringSleep = storage.object(forKey: Key.inhibitChargingDuringSleep) as? Bool ?? true
    }

    func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value
        storage.set(value, forKey: Key.isEnabled)
    }

    func setLimitPercent(_ value: Int) {
        let clamped = Self.clampLimit(value)
        guard limitPercent != clamped else { return }
        limitPercent = clamped
        storage.set(clamped, forKey: Key.limitPercent)
        if floorPercent >= limitPercent {
            setFloorPercent(limitPercent - BatteryChargeLimits.percentStep)
        }
    }

    func setMode(_ value: BatteryChargeMode) {
        guard mode != value else { return }
        mode = value
        storage.set(value.rawValue, forKey: Key.mode)
    }

    func setFloorPercent(_ value: Int) {
        let upper = max(BatteryChargeLimits.minimumPercent, limitPercent - BatteryChargeLimits.percentStep)
        let clamped = min(max(value, BatteryChargeLimits.minimumFloorPercent), upper)
        guard floorPercent != clamped else { return }
        floorPercent = clamped
        storage.set(clamped, forKey: Key.floorPercent)
    }

    func setFloorReminderEnabled(_ value: Bool) {
        guard floorReminderEnabled != value else { return }
        floorReminderEnabled = value
        storage.set(value, forKey: Key.floorReminderEnabled)
    }

    func setThermalProtectionEnabled(_ value: Bool) {
        guard thermalProtectionEnabled != value else { return }
        thermalProtectionEnabled = value
        storage.set(value, forKey: Key.thermalProtectionEnabled)
    }

    func setThermalThresholdCelsius(_ value: Int) {
        let clamped = Self.clampThermal(value)
        guard thermalThresholdCelsius != clamped else { return }
        thermalThresholdCelsius = clamped
        storage.set(clamped, forKey: Key.thermalThresholdCelsius)
    }

    func setInhibitChargingDuringSleep(_ value: Bool) {
        guard inhibitChargingDuringSleep != value else { return }
        inhibitChargingDuringSleep = value
        storage.set(value, forKey: Key.inhibitChargingDuringSleep)
    }

    var isThermalReminderMutedToday: Bool {
        storage.string(forKey: Key.thermalMuteDay) == Self.dayStamp(Date())
    }

    func muteThermalReminderForToday() {
        storage.set(Self.dayStamp(Date()), forKey: Key.thermalMuteDay)
    }

    private static func clampLimit(_ value: Int) -> Int {
        max(BatteryChargeLimits.minimumPercent, min(BatteryChargeLimits.maximumPercent, value))
    }

    private static func clampFloor(_ value: Int) -> Int {
        max(
            BatteryChargeLimits.minimumFloorPercent,
            min(BatteryChargeLimits.maximumFloorPercent, value)
        )
    }

    private static func clampThermal(_ value: Int) -> Int {
        max(
            BatteryChargeLimits.minimumThermalThresholdCelsius,
            min(BatteryChargeLimits.maximumThermalThresholdCelsius, value)
        )
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
