import Foundation
import MacToolsPluginKit

@MainActor
final class DeviceBatteryStore: ObservableObject {
    private enum Key {
        static let layoutMode = "layout-mode"
        static let showInternalBattery = "show-internal-battery"
        static let showBluetoothDevices = "show-bluetooth-devices"
        static let showAppleMobileDevices = "show-apple-mobile-devices"
        static let showVendorHIDDevices = "show-rapoo-devices"  // storage key kept for backward compatibility
        static let lowBatteryNotificationEnabled = "low-battery-notification-enabled"
        static let lowBatteryNotificationThreshold = "low-battery-notification-threshold"
    }

    @Published private(set) var layoutMode: DeviceBatteryLayoutMode
    @Published private(set) var showInternalBattery: Bool
    @Published private(set) var showBluetoothDevices: Bool
    @Published private(set) var showAppleMobileDevices: Bool
    @Published private(set) var showVendorHIDDevices: Bool
    @Published private(set) var lowBatteryNotificationEnabled: Bool
    @Published private(set) var lowBatteryNotificationThreshold: Int

    private let storage: any PluginStorage

    init(storage: any PluginStorage) {
        self.storage = storage
        layoutMode = DeviceBatteryLayoutMode(
            rawValue: storage.string(forKey: Key.layoutMode) ?? DeviceBatteryLayoutMode.grid.rawValue
        ) ?? .grid
        showInternalBattery = Self.boolValue(storage, key: Key.showInternalBattery, defaultValue: true)
        showBluetoothDevices = Self.boolValue(storage, key: Key.showBluetoothDevices, defaultValue: true)
        showAppleMobileDevices = Self.boolValue(storage, key: Key.showAppleMobileDevices, defaultValue: true)
        showVendorHIDDevices = Self.boolValue(storage, key: Key.showVendorHIDDevices, defaultValue: true)
        lowBatteryNotificationEnabled = Self.boolValue(
            storage,
            key: Key.lowBatteryNotificationEnabled,
            defaultValue: false
        )
        lowBatteryNotificationThreshold = Self.normalizedLowBatteryNotificationThreshold(
            storage.object(forKey: Key.lowBatteryNotificationThreshold) == nil
                ? DeviceBatteryLowBatteryThresholds.defaultValue
                : storage.integer(forKey: Key.lowBatteryNotificationThreshold)
        )
    }

    func setLayoutMode(_ mode: DeviceBatteryLayoutMode) {
        guard layoutMode != mode else {
            return
        }

        layoutMode = mode
        storage.set(mode.rawValue, forKey: Key.layoutMode)
    }

    func setShowInternalBattery(_ isShown: Bool) {
        guard showInternalBattery != isShown else {
            return
        }

        showInternalBattery = isShown
        storage.set(isShown, forKey: Key.showInternalBattery)
    }

    func setShowBluetoothDevices(_ isShown: Bool) {
        guard showBluetoothDevices != isShown else {
            return
        }

        showBluetoothDevices = isShown
        storage.set(isShown, forKey: Key.showBluetoothDevices)
    }

    func setShowAppleMobileDevices(_ isShown: Bool) {
        guard showAppleMobileDevices != isShown else {
            return
        }

        showAppleMobileDevices = isShown
        storage.set(isShown, forKey: Key.showAppleMobileDevices)
    }

    func setShowVendorHIDDevices(_ isShown: Bool) {
        guard showVendorHIDDevices != isShown else {
            return
        }

        showVendorHIDDevices = isShown
        storage.set(isShown, forKey: Key.showVendorHIDDevices)
    }

    func setLowBatteryNotificationEnabled(_ isEnabled: Bool) {
        guard lowBatteryNotificationEnabled != isEnabled else {
            return
        }

        lowBatteryNotificationEnabled = isEnabled
        storage.set(isEnabled, forKey: Key.lowBatteryNotificationEnabled)
    }

    func setLowBatteryNotificationThreshold(_ threshold: Int) {
        let normalizedThreshold = Self.normalizedLowBatteryNotificationThreshold(threshold)
        guard lowBatteryNotificationThreshold != normalizedThreshold else {
            return
        }

        lowBatteryNotificationThreshold = normalizedThreshold
        storage.set(normalizedThreshold, forKey: Key.lowBatteryNotificationThreshold)
    }

    static func normalizedLowBatteryNotificationThreshold(_ threshold: Int) -> Int {
        DeviceBatteryLowBatteryThresholds.normalized(threshold)
    }

    private static func boolValue(
        _ storage: any PluginStorage,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard storage.object(forKey: key) != nil else {
            return defaultValue
        }

        return storage.bool(forKey: key)
    }
}
