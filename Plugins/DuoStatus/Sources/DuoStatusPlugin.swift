import Combine
import MacToolsPluginKit
import SwiftUI

public final class DuoStatusPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DuoStatusPluginProvider(context: context)
    }
}

@MainActor
private struct DuoStatusPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DuoStatusPlugin(context: context)]
    }
}

@MainActor
final class DuoStatusPlugin: MacToolsPlugin, PluginSettingsPresenting,
    PluginApplicationActivityStateHandling, PluginMenuBarIconProviding,
    PluginMenuBarIconHostContextConsuming {
    static let pluginID = "duo-status"
    static let iconID = "status"

    private enum SettingsID {
        static let menuBar = "menu-bar"
        static let placement = "placement"

        static let appearance = "appearance"
        static let iconSize = "icon-size"

        static let battery = "battery"
        static let showsBatteryPercentage = "shows-battery-percentage"
        static let showsPercentageWhenConnected = "shows-percentage-when-connected"
        static let showsChargingIndicator = "shows-charging-indicator"
        static let usesBatteryStatusColors = "uses-battery-status-colors"
        static let batteryCriticalThreshold = "battery-critical-threshold"

        static let network = "network"
        static let distinguishesNoInternet = "distinguishes-no-internet"
        static let distinguishesHotspot = "distinguishes-hotspot"
        static let distinguishesTemporaryNetwork = "distinguishes-temporary-network"
        static let distinguishesInternetSharing = "distinguishes-internet-sharing"

        static let audio = "audio"
        static let bottomIndicator = "bottom-indicator"
        static let volumeStyle = "volume-style"
        static let showsBluetoothAudioGlyph = "shows-bluetooth-audio-glyph"
        static let bluetoothGlyphPrioritizesNetworkErrors = "bluetooth-glyph-prioritizes-network-errors"
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    var onMenuBarIconChange: ((String) -> Void)?
    var menuBarIconHostContext: PluginMenuBarIconHostContext? {
        didSet { applyConfiguration() }
    }
    private let localization: PluginLocalization
    private let monitor: any DuoSystemStatusMonitoring
    private let menuBar: any DuoStatusMenuBarPresenting
    private let optionsStore: DuoStatusIconOptionsStore
    private var options: DuoStatusIconOptions
    private var localizationSubscription: AnyCancellable?
    private var isActive = false
    private var activityState: PluginApplicationActivityState = .interactive
    private var placementError: PluginMenuBarIconPlacementError?
    private var iconRevision: UInt64 = 0
    private var cachedIcon: (PluginMenuBarIconRenderContext, PluginMenuBarIconSnapshot)?

    var placement: PluginMenuBarIconPlacement {
        menuBarIconHostContext?.placement(for: Self.iconID) ?? .standalone
    }

    init(
        context: PluginRuntimeContext,
        monitor: (any DuoSystemStatusMonitoring)? = nil,
        menuBar: (any DuoStatusMenuBarPresenting)? = nil
    ) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        optionsStore = DuoStatusIconOptionsStore(storage: context.storage)
        options = optionsStore.load()
        self.monitor = monitor ?? DuoSystemStatusMonitor()
        self.menuBar = menuBar ?? DuoStatusMenuBarController()
        self.monitor.onChange = { [weak self] snapshot in
            guard let self, self.isActive, self.menuBarIconHostContext != nil,
                  self.activityState.allowsBackgroundWork else { return }
            self.iconDidChange(snapshot: snapshot)
        }
        self.menuBar.openSettings = { [weak self] in
            guard let self, self.isActive, self.menuBarIconHostContext != nil,
                  self.placement == .standalone else { return }
            self.requestSettingsPresentation?()
        }
    }

    isolated deinit {
        monitor.onChange = nil
        monitor.stop()
        menuBar.openSettings = nil
        menuBar.remove()
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "Duo 状态"),
            iconName: "wifi.circle",
            iconTint: .green,
            order: 24,
            defaultDescription: localization.string(
                "metadata.description", defaultValue: "通过独立图标或应用主图标查看电量与网络状态"
            )
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(sections: [
            menuBarSection, appearanceSection, batterySection, networkSection, audioSection
        ])
    }

    private var menuBarSection: PluginSettingsSection {
        PluginSettingsSection(
                id: SettingsID.menuBar,
                title: localization.string("settings.menuBar", defaultValue: "菜单栏"),
                systemImage: "menubar.rectangle",
                footer: menuBarFooter,
                rows: [
                    PluginSettingsRow(
                        id: SettingsID.placement,
                        title: localization.string("settings.placement", defaultValue: "显示方式"),
                        description: placement == .primary
                            ? localization.string("settings.primaryDescription", defaultValue: "替换 MacTools 主图标，点击行为保持不变。")
                            : localization.string("settings.standaloneDescription", defaultValue: "独立显示，悬停查看状态，点击打开设置。"),
                        error: placementErrorMessage,
                        isEnabled: menuBarIconHostContext != nil,
                        control: .picker(
                            selectionID: placement.rawValue,
                            options: [
                                .init(id: PluginMenuBarIconPlacement.standalone.rawValue,
                                      title: localization.string("settings.standalone", defaultValue: "独立图标")),
                                .init(id: PluginMenuBarIconPlacement.primary.rawValue,
                                      title: localization.string("settings.primary", defaultValue: "替换应用图标"))
                            ],
                            style: .segmented
                        )
                    )
                ]
            )
    }

    private var appearanceSection: PluginSettingsSection {
        PluginSettingsSection(
            id: SettingsID.appearance,
            title: localization.string("settings.appearance", defaultValue: "外观"),
            systemImage: "paintbrush",
            rows: [
                PluginSettingsRow(
                    id: SettingsID.iconSize,
                    title: localization.string("settings.iconSize", defaultValue: "图标大小"),
                    description: localization.string(
                        "settings.iconSizeDescription", defaultValue: "调整菜单栏图标的整体尺寸。"
                    ),
                    control: .picker(
                        selectionID: options.iconSize.rawValue,
                        options: [
                            .init(id: DuoStatusIconSize.small.rawValue,
                                  title: localization.string("settings.iconSizeSmall", defaultValue: "小")),
                            .init(id: DuoStatusIconSize.medium.rawValue,
                                  title: localization.string("settings.iconSizeMedium", defaultValue: "中")),
                            .init(id: DuoStatusIconSize.large.rawValue,
                                  title: localization.string("settings.iconSizeLarge", defaultValue: "大"))
                        ],
                        style: .segmented
                    )
                )
            ]
        )
    }

    private var batterySection: PluginSettingsSection {
        PluginSettingsSection(
            id: SettingsID.battery,
            title: localization.string("settings.battery", defaultValue: "电量"),
            systemImage: "battery.75percent",
            rows: [
                PluginSettingsRow(
                    id: SettingsID.showsBatteryPercentage,
                    title: localization.string("settings.showsPercentage", defaultValue: "显示电量百分比"),
                    description: localization.string(
                        "settings.showsPercentageDescription", defaultValue: "在圆环顶部缺口显示电量数字。"
                    ),
                    control: .toggle(isOn: options.showsBatteryPercentage)
                ),
                PluginSettingsRow(
                    id: SettingsID.showsPercentageWhenConnected,
                    title: localization.string(
                        "settings.percentageWhenConnected", defaultValue: "接通电源时显示百分比"
                    ),
                    description: localization.string(
                        "settings.percentageWhenConnectedDescription",
                        defaultValue: "关闭后，接通电源时仅显示充电标记。"
                    ),
                    isEnabled: options.showsBatteryPercentage,
                    control: .toggle(isOn: options.showsPercentageWhenConnected)
                ),
                PluginSettingsRow(
                    id: SettingsID.showsChargingIndicator,
                    title: localization.string("settings.chargingIndicator", defaultValue: "显示充电标记"),
                    description: localization.string(
                        "settings.chargingIndicatorDescription", defaultValue: "充电或接通电源时显示闪电标记。"
                    ),
                    control: .toggle(isOn: options.showsChargingIndicator)
                ),
                PluginSettingsRow(
                    id: SettingsID.usesBatteryStatusColors,
                    title: localization.string("settings.statusColors", defaultValue: "使用状态颜色"),
                    description: localization.string(
                        "settings.statusColorsDescription",
                        defaultValue: "低电量、低电量模式与充电使用不同颜色。"
                    ),
                    control: .toggle(isOn: options.usesBatteryStatusColors)
                ),
                PluginSettingsRow(
                    id: SettingsID.batteryCriticalThreshold,
                    title: localization.string("settings.criticalThreshold", defaultValue: "低电量阈值"),
                    description: localization.string(
                        "settings.criticalThresholdDescription", defaultValue: "电量低于此值时以警示颜色显示。"
                    ),
                    isEnabled: options.usesBatteryStatusColors,
                    control: .slider(
                        value: Double(options.batteryCriticalThreshold),
                        range: Double(DuoStatusIconOptionsStore.criticalThresholdRange.lowerBound)
                            ... Double(DuoStatusIconOptionsStore.criticalThresholdRange.upperBound),
                        step: Double(DuoStatusIconOptionsStore.criticalThresholdStep),
                        valueFormat: .percentage
                    )
                )
            ]
        )
    }

    private var networkSection: PluginSettingsSection {
        PluginSettingsSection(
            id: SettingsID.network,
            title: localization.string("settings.network", defaultValue: "网络"),
            systemImage: "wifi",
            footer: localization.string(
                "settings.networkFooter",
                defaultValue: "开启后，对应状态显示专用图标，而不是普通 Wi-Fi 图标。"
            ),
            rows: [
                PluginSettingsRow(
                    id: SettingsID.distinguishesNoInternet,
                    title: localization.string(
                        "settings.noInternet", defaultValue: "区分「已连接但无法上网」"
                    ),
                    control: .toggle(isOn: options.distinguishesNoInternet)
                ),
                PluginSettingsRow(
                    id: SettingsID.distinguishesHotspot,
                    title: localization.string("settings.hotspot", defaultValue: "区分「个人热点」"),
                    control: .toggle(isOn: options.distinguishesHotspot)
                ),
                PluginSettingsRow(
                    id: SettingsID.distinguishesTemporaryNetwork,
                    title: localization.string("settings.temporary", defaultValue: "区分「临时网络」"),
                    control: .toggle(isOn: options.distinguishesTemporaryNetwork)
                ),
                PluginSettingsRow(
                    id: SettingsID.distinguishesInternetSharing,
                    title: localization.string("settings.sharing", defaultValue: "区分「互联网共享」"),
                    control: .toggle(isOn: options.distinguishesInternetSharing)
                )
            ]
        )
    }

    private var menuBarFooter: String {
        if DuoStatusIconMappings.usesVolumeBar(options: options) {
            return localization.string(
                "settings.footerVolumeBar",
                defaultValue: "圆弧显示电量，中心显示网络状态，底部进度条显示音量。"
            )
        }
        if options.bottomIndicator == .volume {
            return localization.string(
                "settings.footerVolume",
                defaultValue: "圆弧显示电量，中心显示网络状态，底部圆点显示音量。"
            )
        }
        return localization.string(
            "settings.footer",
            defaultValue: "圆弧显示电量，中心显示网络状态，底部圆点显示 Wi-Fi 信号。"
        )
    }

    private var audioSection: PluginSettingsSection {
        var rows = [
            PluginSettingsRow(
                id: SettingsID.bottomIndicator,
                title: localization.string("settings.bottomIndicator", defaultValue: "底部指示"),
                description: localization.string(
                    "settings.bottomIndicatorDescription", defaultValue: "选择圆环底部显示的内容。"
                ),
                control: .picker(
                    selectionID: options.bottomIndicator.rawValue,
                    options: [
                        .init(id: DuoStatusBottomIndicator.wifi.rawValue,
                              title: localization.string("settings.indicatorWiFi", defaultValue: "Wi-Fi 信号")),
                        .init(id: DuoStatusBottomIndicator.volume.rawValue,
                              title: localization.string("settings.indicatorVolume", defaultValue: "音量"))
                    ],
                    style: .segmented
                )
            )
        ]
        // Wi-Fi signal only has four steps, so the style choice exists for volume alone.
        if options.bottomIndicator == .volume {
            rows.append(PluginSettingsRow(
                id: SettingsID.volumeStyle,
                title: localization.string("settings.volumeStyle", defaultValue: "音量样式"),
                description: localization.string(
                    "settings.volumeStyleDescription", defaultValue: "以圆点分档显示，或以进度条连续显示。"
                ),
                control: .picker(
                    selectionID: options.volumeStyle.rawValue,
                    options: [
                        .init(id: DuoStatusVolumeStyle.dots.rawValue,
                              title: localization.string("settings.volumeStyleDots", defaultValue: "圆点")),
                        .init(id: DuoStatusVolumeStyle.bar.rawValue,
                              title: localization.string("settings.volumeStyleBar", defaultValue: "进度条"))
                    ],
                    style: .segmented
                )
            ))
        }
        rows += [
            PluginSettingsRow(
                id: SettingsID.showsBluetoothAudioGlyph,
                title: localization.string(
                    "settings.bluetoothGlyph", defaultValue: "蓝牙输出时替换网络图标"
                ),
                description: localization.string(
                    "settings.bluetoothGlyphDescription", defaultValue: "使用蓝牙音频设备时显示蓝牙标记。"
                ),
                control: .toggle(isOn: options.showsBluetoothAudioGlyph)
            ),
            PluginSettingsRow(
                id: SettingsID.bluetoothGlyphPrioritizesNetworkErrors,
                title: localization.string("settings.networkErrorsFirst", defaultValue: "网络异常优先"),
                description: localization.string(
                    "settings.networkErrorsFirstDescription",
                    defaultValue: "网络异常时仍显示网络状态，而不是蓝牙标记。"
                ),
                isEnabled: options.showsBluetoothAudioGlyph,
                control: .toggle(isOn: options.bluetoothGlyphPrioritizesNetworkErrors)
            )
        ]
        return PluginSettingsSection(
            id: SettingsID.audio,
            title: localization.string("settings.audio", defaultValue: "音量与音频"),
            systemImage: "speaker.wave.2",
            rows: rows
        )
    }

    func activate(context: PluginRuntimeContext) {
        guard !isActive else { return }
        isActive = true
        localizationSubscription = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                // Locale-source publication happens before its revision changes.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.iconDidChange(snapshot: self.monitor.snapshot)
                }
            }
        applyConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActive = false
        localizationSubscription = nil
        monitor.stop()
        menuBar.remove()
    }

    func refresh() {
        applyConfiguration()
        monitor.refresh()
        onStateChange?()
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        activityState = state
        applyConfiguration()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        var updated = options
        switch action {
        case let .setSelection(id, optionID):
            switch id {
            case SettingsID.placement:
                guard let placement = PluginMenuBarIconPlacement(rawValue: optionID) else { return }
                applyPlacement(placement)
                return
            case SettingsID.iconSize:
                guard let size = DuoStatusIconSize(rawValue: optionID) else { return }
                updated.iconSize = size
            case SettingsID.bottomIndicator:
                guard let indicator = DuoStatusBottomIndicator(rawValue: optionID) else { return }
                updated.bottomIndicator = indicator
            case SettingsID.volumeStyle:
                guard let style = DuoStatusVolumeStyle(rawValue: optionID) else { return }
                updated.volumeStyle = style
            default:
                return
            }
        case let .setBoolean(id, isOn):
            switch id {
            case SettingsID.showsBatteryPercentage: updated.showsBatteryPercentage = isOn
            case SettingsID.showsPercentageWhenConnected: updated.showsPercentageWhenConnected = isOn
            case SettingsID.showsChargingIndicator: updated.showsChargingIndicator = isOn
            case SettingsID.usesBatteryStatusColors: updated.usesBatteryStatusColors = isOn
            case SettingsID.distinguishesNoInternet: updated.distinguishesNoInternet = isOn
            case SettingsID.distinguishesHotspot: updated.distinguishesHotspot = isOn
            case SettingsID.distinguishesTemporaryNetwork: updated.distinguishesTemporaryNetwork = isOn
            case SettingsID.distinguishesInternetSharing: updated.distinguishesInternetSharing = isOn
            case SettingsID.showsBluetoothAudioGlyph: updated.showsBluetoothAudioGlyph = isOn
            case SettingsID.bluetoothGlyphPrioritizesNetworkErrors:
                updated.bluetoothGlyphPrioritizesNetworkErrors = isOn
            default: return
            }
        case let .setNumber(id, value, phase):
            // Persist only the committed value so dragging the slider does not
            // churn storage or the icon cache on every intermediate frame.
            guard id == SettingsID.batteryCriticalThreshold, phase == .committed else { return }
            updated.batteryCriticalThreshold = DuoStatusIconOptionsStore.clampedThreshold(
                Int(value.rounded())
            )
        default:
            return
        }
        commit(updated)
    }

    private func applyPlacement(_ placement: PluginMenuBarIconPlacement) {
        let result = menuBarIconHostContext?.requestPlacement(placement, for: Self.iconID)
            ?? .failure(.unavailable)
        switch result {
        case .success:
            placementError = nil
            applyConfiguration()
        case let .failure(error):
            placementError = error
        }
        onStateChange?()
    }

    private func commit(_ updated: DuoStatusIconOptions) {
        guard updated != options else { return }
        options = updated
        optionsStore.save(updated)
        iconRevision &+= 1
        cachedIcon = nil
        // The refresh scope may have gained or lost audio, so re-apply it before
        // redrawing; the monitor installs or tears down its CoreAudio listeners here.
        monitor.setRefreshScope(refreshScope)
        updateMenuBar(snapshot: monitor.snapshot)
        onMenuBarIconChange?(Self.iconID)
        onStateChange?()
    }

    /// Audio is sampled only when a selected option actually renders it.
    private var refreshScope: DuoSystemStatusRefreshScope {
        var scope: DuoSystemStatusRefreshScope = [.battery, .wifi]
        if options.bottomIndicator == .volume || options.showsBluetoothAudioGlyph {
            scope.insert(.volume)
        }
        return scope
    }

    var menuBarIconDescriptors: [PluginMenuBarIconDescriptor] {
        [.init(id: Self.iconID, title: metadata.title)]
    }

    func menuBarIcon(
        for iconID: String,
        context: PluginMenuBarIconRenderContext
    ) -> PluginMenuBarIconSnapshot? {
        guard iconID == Self.iconID else { return nil }
        if let cachedIcon, cachedIcon.0 == context { return cachedIcon.1 }
        let image = DuoStatusIcon.image(
            for: monitor.snapshot,
            options: options,
            appearance: context.appearance == .dark ? .dark : .light,
            pointSize: context.pointSize
        )
        let description = "\(metadata.title)\n\(statusDescription.text(for: monitor.snapshot))"
        let snapshot = PluginMenuBarIconSnapshot(
            revision: iconRevision,
            image: image,
            isTemplate: image.isTemplate,
            tooltip: description,
            accessibilityDescription: description
        )
        cachedIcon = (context, snapshot)
        return snapshot
    }

    func menuBarIconPlacementDidChange() {
        placementError = nil
        applyConfiguration()
        onStateChange?()
    }

    private var placementErrorMessage: String? {
        switch placementError {
        case let .occupied(owner):
            let owner = menuBarIconHostContext?.primaryIconOwner ?? owner
            if owner.requiresRestart {
                return localization.format(
                    "settings.occupiedPendingRestartFormat",
                    defaultValue: "「%@」正在等待重启。请重启 MacTools 后调整其图标设置。",
                    owner.pluginTitle
                )
            }
            return localization.format(
                "settings.occupiedFormat",
                defaultValue: "应用图标已由「%@」使用。请先在其设置中取消替换。",
                owner.pluginTitle
            )
        case .unavailable:
            return localization.string("settings.unavailable", defaultValue: "暂时无法切换显示方式，请稍后重试。")
        case .invalidIcon:
            return localization.string("settings.invalidIcon", defaultValue: "图标暂不可用，已保留当前显示方式。")
        case nil:
            return nil
        }
    }

    private func applyConfiguration() {
        // Wait for host registration so a restored primary placement never creates a duplicate item.
        guard isActive, menuBarIconHostContext != nil else {
            monitor.stop()
            menuBar.remove()
            return
        }
        if activityState.allowsBackgroundWork {
            monitor.setRefreshScope(refreshScope)
            monitor.start()
        } else {
            monitor.stop()
        }
        updateMenuBar(snapshot: monitor.snapshot)
    }

    private func updateMenuBar(snapshot: DuoSystemStatusSnapshot) {
        guard isActive, menuBarIconHostContext != nil else { return }
        guard placement == .standalone else {
            menuBar.remove()
            return
        }
        let status = statusDescription.text(for: snapshot)
        menuBar.update(snapshot: snapshot, options: options, tooltip: "\(metadata.title)\n\(status)")
    }

    /// The tooltip names whichever quantity the bottom dots currently show, so it
    /// has to be rebuilt from the live options rather than cached.
    private var statusDescription: DuoSystemStatusDescription {
        DuoSystemStatusDescription(localization: localization, options: options)
    }

    private func iconDidChange(snapshot: DuoSystemStatusSnapshot) {
        guard isActive else { return }
        iconRevision &+= 1
        cachedIcon = nil
        updateMenuBar(snapshot: snapshot)
        onMenuBarIconChange?(Self.iconID)
    }
}
