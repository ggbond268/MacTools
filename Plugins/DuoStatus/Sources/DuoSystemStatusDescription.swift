import MacToolsPluginKit

struct DuoSystemStatusDescription {
    let localization: PluginLocalization
    var options: DuoStatusIconOptions = .default

    /// The tooltip always names the precise Wi-Fi state, even when the matching
    /// `distinguishes*` option is off and the icon collapses it to the plain fan.
    func text(for snapshot: DuoSystemStatusSnapshot) -> String {
        var lines = [batteryText(snapshot), wifiText(snapshot), networkText(snapshot.network)]
        if options.bottomIndicator == .volume {
            lines.append(volumeText(snapshot.volume))
        }
        return lines.joined(separator: "\n")
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

    private func wifiText(_ snapshot: DuoSystemStatusSnapshot) -> String {
        switch snapshot.wifi {
        case .connected:
            localization.format("status.wifiLevelFormat", defaultValue: "Wi-Fi 信号 %d/4", snapshot.wifiLevel)
        case .noInternet:
            localization.string("status.wifiNoInternet", defaultValue: "Wi-Fi 已连接，但无法访问互联网")
        case .hotspot:
            localization.format("status.wifiHotspotFormat", defaultValue: "已连接个人热点，信号 %d/4", snapshot.wifiLevel)
        case .temporary:
            localization.format("status.wifiTemporaryFormat", defaultValue: "已连接临时网络，信号 %d/4", snapshot.wifiLevel)
        case .shared:
            localization.string("status.wifiShared", defaultValue: "正在共享互联网连接")
        case .off:
            localization.string("status.wifiOff", defaultValue: "Wi-Fi 已关闭")
        case .disconnected:
            localization.string("status.wifiDisconnected", defaultValue: "Wi-Fi 未连接")
        case .unavailable:
            localization.string("status.wifiUnavailable", defaultValue: "Wi-Fi 信号暂不可用")
        }
    }

    private func volumeText(_ volume: DuoSystemStatusSnapshot.Volume) -> String {
        if volume.isMuted {
            return localization.string("status.volumeMuted", defaultValue: "音量已静音")
        }
        guard let scalar = volume.scalar, scalar.isFinite else {
            return localization.string("status.volumeUnavailable", defaultValue: "音量暂不可用")
        }
        let percentage = Int((min(1, max(0, scalar)) * 100).rounded())
        return localization.format("status.volumeFormat", defaultValue: "音量 %d%%", percentage)
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
