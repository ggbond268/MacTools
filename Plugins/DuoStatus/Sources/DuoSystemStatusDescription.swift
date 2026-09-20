import MacToolsPluginKit

struct DuoSystemStatusDescription {
    let localization: PluginLocalization

    func text(for snapshot: DuoSystemStatusSnapshot) -> String {
        [batteryText(snapshot), wifiText(snapshot.wifi), networkText(snapshot.network)].joined(separator: "\n")
    }

    private func batteryText(_ snapshot: DuoSystemStatusSnapshot) -> String {
        guard let fraction = snapshot.batteryFraction, fraction.isFinite else {
            return snapshot.battery == .notPresent
                ? localization.string("status.noBattery", defaultValue: "无内置电池")
                : localization.string("status.batteryUnavailable", defaultValue: "电量暂不可用")
        }
        let percentage = Int((min(1, max(0, fraction)) * 100).rounded())
        if snapshot.isCharging {
            return localization.format("status.chargingFormat", defaultValue: "电量 %d%%，正在充电", percentage)
        }
        if snapshot.isExternalPowerConnected {
            return localization.format("status.externalPowerFormat", defaultValue: "电量 %d%%，已接通电源", percentage)
        }
        return localization.format("status.batteryFormat", defaultValue: "电量 %d%%", percentage)
    }

    private func wifiText(_ wifi: DuoSystemStatusSnapshot.WiFi) -> String {
        switch wifi {
        case let .connected(level):
            localization.format("status.wifiLevelFormat", defaultValue: "Wi-Fi 信号 %d/4", min(4, max(0, level)))
        case .off:
            localization.string("status.wifiOff", defaultValue: "Wi-Fi 已关闭")
        case .disconnected:
            localization.string("status.wifiDisconnected", defaultValue: "Wi-Fi 未连接")
        case .unavailable:
            localization.string("status.wifiUnavailable", defaultValue: "Wi-Fi 信号暂不可用")
        }
    }

    private func networkText(_ network: DuoSystemStatusSnapshot.Network) -> String {
        switch network {
        case .connected:
            localization.string("status.networkConnected", defaultValue: "网络已连接")
        case .disconnected:
            localization.string("status.networkDisconnected", defaultValue: "网络未连接")
        case .requiresConnection:
            localization.string("status.networkConnecting", defaultValue: "网络等待连接")
        case .unknown:
            localization.string("status.networkUnknown", defaultValue: "网络状态暂不可用")
        }
    }
}
