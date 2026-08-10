import Foundation
import MacToolsPluginKit
@preconcurrency import UserNotifications

@MainActor
protocol BatteryChargeLimitNotifying: AnyObject {
    func notifyFloorReminder(level: Int, floor: Int, localization: PluginLocalization)
    func notifyThermalProtection(temperature: Double, threshold: Int, localization: PluginLocalization)
}

@MainActor
final class BatteryChargeLimitUserNotifier: BatteryChargeLimitNotifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notifyFloorReminder(level: Int, floor: Int, localization: PluginLocalization) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = localization.string(
            "notification.floor.title",
            defaultValue: "电量偏低"
        )
        content.body = localization.format(
            "notification.floor.body",
            defaultValue: "当前电量 %d%%，已低于下限 %d%%，请接入电源。",
            level,
            floor
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "battery-charge-limit.floor.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func notifyThermalProtection(temperature: Double, threshold: Int, localization: PluginLocalization) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = localization.string(
            "notification.thermal.title",
            defaultValue: "电池热保护"
        )
        content.body = localization.format(
            "notification.thermal.body",
            defaultValue: "电池温度约 %.0f°C，已超过 %d°C，已暂停充电。",
            temperature,
            threshold
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "battery-charge-limit.thermal.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
}
