import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class BatteryChargeLimitPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        BatteryChargeLimitPluginProvider(context: context)
    }
}

@MainActor
private struct BatteryChargeLimitPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [
            BatteryChargeLimitPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

// MARK: - Control IDs

private enum ControlID {
    static let enableAction    = "battery-enable-action"
    static let limitSlider     = "battery-limit-slider"
    static let floorSlider     = "battery-floor-slider"
    static let floorReminderToggle = "battery-floor-reminder"
    static let thermalToggle   = "battery-thermal-toggle"
    static let thermalSlider   = "battery-thermal-slider"
    static let sleepInhibitToggle = "battery-sleep-inhibit"
    static let chargeAction    = "battery-charge-action"
    static let dischargeAction = "battery-discharge-action"
    static let manageSettings  = "battery-manage-settings"
    static let missingHelper   = "battery-missing-helper"
}

// MARK: - Plugin

@MainActor
final class BatteryChargeLimitPlugin: MacToolsPlugin, PluginPrimaryPanel {

    // MARK: Metadata

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: State

    let store: BatteryChargeLimitStore
    private let localization: PluginLocalization
    private let reader: any BatteryChargeLimitReading
    private let writer: any BatteryChargeLimitWriting
    private let notifier: any BatteryChargeLimitNotifying

    private var isExpanded = false
    private var batterySnapshot: BatterySnapshot = .empty
    private var capabilities: BatterySMCCapabilities = .none
    private var lastErrorMessage: String?
    private var requiresSMCCleanup = false
    private var monitoringTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private var didNotifyFloorReminder = false
    private var didNotifyThermalThisSession = false

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "battery-charge-limit"),
        reader: any BatteryChargeLimitReading = BatteryChargeLimitReader(),
        writer: (any BatteryChargeLimitWriting)? = nil,
        notifier: any BatteryChargeLimitNotifying = BatteryChargeLimitUserNotifier(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "battery-charge-limit",
            title: localization.string("metadata.title", defaultValue: "电池充电上限"),
            iconName: "battery.100.bolt",
            iconTint: Color(nsColor: .systemGreen),
            order: 48,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "限制电池充电至指定上限，并提供下限提醒与热保护"
            )
        )
        self.store = BatteryChargeLimitStore(storage: context.storage)
        self.reader = reader
        self.writer = writer ?? BatteryChargeLimitWriter(resourceBundle: context.resourceBundle)
        self.notifier = notifier
    }

    // MARK: - Lifecycle

    func activate(context: PluginRuntimeContext) {
        batterySnapshot = reader.readSnapshot()

        // Re-assert the persisted mode after app restart. SMC keys can be
        // reset by firmware across sleep/hibernation, so on launch we
        // re-apply whatever the user last had configured.
        if store.isEnabled {
            startActiveMonitoring()
            applyCurrentMode(reason: "activate")
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopActiveMonitoring()
        if reason.requiresStateCleanup {
            restoreUnrestrictedChargingIfNeeded(reason: String(describing: reason), requireInstalledHelper: true)
        }
    }

    func refresh() {
        batterySnapshot = reader.readSnapshot()
        evaluateAutoTransitions()
        onStateChange?()
    }

    // MARK: - PluginPrimaryPanel

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: store.isEnabled,
            isExpanded: isExpanded,
            isEnabled: batterySnapshot.hasBattery,
            isVisible: batterySnapshot.hasBattery,
            detail: isExpanded ? buildDetail() : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "charge-limit",
                    title: localization.string("settings.limit.title", defaultValue: "充电上限"),
                    systemImage: "battery.75",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.limitSlider,
                            title: localization.string("settings.limit.target", defaultValue: "目标电量"),
                            description: localization.string(
                                "settings.limit.description",
                                defaultValue: "达到此电量后自动停止充电。"
                            ),
                            systemImage: "battery.75percent",
                            control: .slider(
                                value: Double(store.limitPercent),
                                range: Double(BatteryChargeLimits.minimumPercent)...Double(BatteryChargeLimits.maximumPercent),
                                step: Double(BatteryChargeLimits.percentStep),
                                valueFormat: .percentage
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "floor-reminder",
                    title: localization.string("settings.floor.title", defaultValue: "下限提醒"),
                    systemImage: "battery.25",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.floorReminderToggle,
                            title: localization.string("settings.floor.toggle", defaultValue: "电量过低时提醒"),
                            description: localization.string(
                                "settings.floor.toggleDescription",
                                defaultValue: "未接电源且电量低于下限时发送通知，不会自动恢复充电。"
                            ),
                            systemImage: "bell.badge",
                            control: .toggle(isOn: store.floorReminderEnabled)
                        ),
                        PluginSettingsRow(
                            id: ControlID.floorSlider,
                            title: localization.string("settings.floor.target", defaultValue: "下限电量"),
                            description: localization.string(
                                "settings.floor.description",
                                defaultValue: "建议接电源的最低电量。"
                            ),
                            systemImage: "arrow.down.to.line",
                            control: .slider(
                                value: Double(store.floorPercent),
                                range: Double(BatteryChargeLimits.minimumFloorPercent)...Double(
                                    max(
                                        BatteryChargeLimits.minimumFloorPercent,
                                        store.limitPercent - BatteryChargeLimits.percentStep
                                    )
                                ),
                                step: Double(BatteryChargeLimits.percentStep),
                                valueFormat: .percentage
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "thermal-protection",
                    title: localization.string("settings.thermal.title", defaultValue: "热保护"),
                    systemImage: "thermometer.medium",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.thermalToggle,
                            title: localization.string("settings.thermal.toggle", defaultValue: "超温暂停充电"),
                            description: localization.string(
                                "settings.thermal.toggleDescription",
                                defaultValue: "充电时电池温度超过阈值则停止充电并通知。"
                            ),
                            systemImage: "flame",
                            control: .toggle(isOn: store.thermalProtectionEnabled)
                        ),
                        PluginSettingsRow(
                            id: ControlID.thermalSlider,
                            title: localization.string("settings.thermal.threshold", defaultValue: "温度阈值"),
                            description: localization.string(
                                "settings.thermal.thresholdDescription",
                                defaultValue: "单位摄氏度。"
                            ),
                            systemImage: "degreesign.celsius",
                            control: .slider(
                                value: Double(store.thermalThresholdCelsius),
                                range: Double(BatteryChargeLimits.minimumThermalThresholdCelsius)...Double(
                                    BatteryChargeLimits.maximumThermalThresholdCelsius
                                ),
                                step: 1,
                                valueFormat: PluginSettingsSliderValueFormat(suffix: " °C")
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "sleep-policy",
                    title: localization.string("settings.sleep.title", defaultValue: "休眠充电"),
                    systemImage: "moon.zzz",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.sleepInhibitToggle,
                            title: localization.string("settings.sleep.inhibit", defaultValue: "休眠时保持停充"),
                            description: localization.string(
                                "settings.sleep.inhibitDescription",
                                defaultValue: "开启后，休眠前会再次写入停充；关闭则休眠期间不额外干预。"
                            ),
                            systemImage: "powersleep",
                            control: .toggle(isOn: store.inhibitChargingDuringSleep)
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "battery-info",
                    title: localization.string("settings.info.title", defaultValue: "电池信息"),
                    systemImage: "info.circle",
                    rows: batteryInfoRows
                ),
                PluginSettingsSection(
                    id: "charging-behavior",
                    title: localization.string("settings.behavior.title", defaultValue: "充电行为"),
                    systemImage: "bolt.badge.checkmark",
                    rows: [
                        PluginSettingsRow(
                            id: "no-auto-resume",
                            title: localization.string(
                                "settings.behavior.noAutoResume.title",
                                defaultValue: "不自动恢复充电"
                            ),
                            description: localization.string(
                                "settings.behavior.noAutoResume.description",
                                defaultValue: "电量低于上限时不会自动充电，需要在菜单栏点击「开始充电」才会继续。"
                            ),
                            systemImage: "pause.circle",
                            control: .status(
                                text: localization.string("settings.status.enabled", defaultValue: "默认行为"),
                                systemImage: "checkmark.circle.fill",
                                tone: .positive,
                                actionTitle: nil
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "hardware-compatibility",
                    title: localization.string("settings.compatibility.title", defaultValue: "硬件兼容"),
                    systemImage: "cpu",
                    rows: hardwareCompatibilityRows
                )
            ]
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if !expanded { lastErrorMessage = nil }
            onStateChange?()

        case let .setSlider(controlID, value, phase):
            guard controlID == ControlID.limitSlider, phase == .ended else { return }
            handleLimitChange(Int(value))

        case let .invokeAction(controlID):
            handleInvokeAction(controlID)

        case .setSwitch, .setSelection, .setNavigationSelection, .clearNavigationSelection, .setDate:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setNumber(controlID, value, phase):
            guard phase == .committed else { return }
            switch controlID {
            case ControlID.limitSlider:
                handleLimitChange(Int(value.rounded()))
            case ControlID.floorSlider:
                store.setFloorPercent(Int(value.rounded()))
                onStateChange?()
            case ControlID.thermalSlider:
                store.setThermalThresholdCelsius(Int(value.rounded()))
                onStateChange?()
            default:
                break
            }

        case let .setBoolean(controlID, value):
            switch controlID {
            case ControlID.floorReminderToggle:
                store.setFloorReminderEnabled(value)
                if !value { didNotifyFloorReminder = false }
                onStateChange?()
            case ControlID.thermalToggle:
                store.setThermalProtectionEnabled(value)
                if !value { didNotifyThermalThisSession = false }
                onStateChange?()
            case ControlID.sleepInhibitToggle:
                store.setInhibitChargingDuringSleep(value)
                onStateChange?()
            default:
                break
            }

        default:
            break
        }
    }
    func handleShortcutAction(id: String) {}

    private var batteryInfoRows: [PluginSettingsRow] {
        let levelText = batterySnapshot.levelPercent.map { "\($0)%" }
            ?? localization.string("settings.info.unavailable", defaultValue: "—")
        let healthText = batterySnapshot.healthPercent.map { "\($0)%" }
            ?? localization.string("settings.info.unavailable", defaultValue: "—")
        let cycleText = batterySnapshot.cycleCount.map(String.init)
            ?? localization.string("settings.info.unavailable", defaultValue: "—")
        let temperatureText = batterySnapshot.temperatureCelsius.map { String(format: "%.0f°C", $0) }
            ?? localization.string("settings.info.unavailable", defaultValue: "—")

        return [
            PluginSettingsRow(
                id: "info-level",
                title: localization.string("settings.info.level", defaultValue: "当前电量"),
                systemImage: "battery.50",
                control: .status(text: levelText, systemImage: "battery.50", tone: .neutral, actionTitle: nil)
            ),
            PluginSettingsRow(
                id: "info-health",
                title: localization.string("settings.info.health", defaultValue: "健康度"),
                systemImage: "heart",
                control: .status(text: healthText, systemImage: "heart", tone: .neutral, actionTitle: nil)
            ),
            PluginSettingsRow(
                id: "info-cycles",
                title: localization.string("settings.info.cycles", defaultValue: "循环次数"),
                systemImage: "arrow.triangle.2.circlepath",
                control: .status(text: cycleText, systemImage: "arrow.triangle.2.circlepath", tone: .neutral, actionTitle: nil)
            ),
            PluginSettingsRow(
                id: "info-temperature",
                title: localization.string("settings.info.temperature", defaultValue: "温度"),
                systemImage: "thermometer",
                control: .status(text: temperatureText, systemImage: "thermometer", tone: .neutral, actionTitle: nil)
            )
        ]
    }

    private var hardwareCompatibilityRows: [PluginSettingsRow] {
        var rows = [
            PluginSettingsRow(
                id: "control-method",
                title: localization.string("settings.compatibility.controlMethod", defaultValue: "充电控制方式"),
                systemImage: "cpu",
                control: .status(
                    text: capabilityDescription,
                    systemImage: capabilities.canInhibit ? "checkmark.circle.fill" : "xmark.circle.fill",
                    tone: capabilities.canInhibit ? .positive : .caution,
                    actionTitle: nil
                )
            )
        ]

        if capabilities.canForceDischarge {
            rows.append(
                PluginSettingsRow(
                    id: "force-discharge",
                    title: localization.string("settings.compatibility.forceDischarge", defaultValue: "强制放电"),
                    systemImage: "battery.25",
                    control: .status(
                        text: localization.string(
                            "settings.compatibility.forceDischarge.supported",
                            defaultValue: "支持（CH0I）"
                        ),
                        systemImage: "checkmark.circle.fill",
                        tone: .positive,
                        actionTitle: nil
                    )
                )
            )
        }

        if capabilities.isBCLMOnly {
            rows.append(
                PluginSettingsRow(
                    id: "intel-limit",
                    title: localization.string("settings.compatibility.intelLimit.title", defaultValue: "Intel Mac 限制"),
                    description: localization.string(
                        "settings.compatibility.intelLimit.description",
                        defaultValue: "当前 Mac 仅支持 BCLM，电量低于上限时仍可能被系统自动充至上限。"
                    ),
                    systemImage: "exclamationmark.triangle",
                    control: .status(
                        text: localization.string("settings.status.limited", defaultValue: "有限支持"),
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .caution,
                        actionTitle: nil
                    )
                )
            )
        }
        return rows
    }

    private var capabilityDescription: String {
        if capabilities.hasCHTE { return "CHTE (macOS 26+)" }
        if capabilities.hasCH0BC { return "CH0B + CH0C (Apple Silicon)" }
        if capabilities.hasBCLM { return "BCLM (Intel)" }
        return localization.string(
            "settings.compatibility.noSMCKey",
            defaultValue: "未检测到可用的 SMC 充电控制键"
        )
    }

    // MARK: - User Actions

    private func handleEnableToggle(_ value: Bool) {
        store.setEnabled(value)
        if value {
            // Probe capabilities lazily — the helper install prompt happens
            // on first call. Surface a clear error if the hardware can't be
            // inhibited.
            capabilities = writer.probeCapabilities()
            if !capabilities.canInhibit && writer.isHelperAvailable {
                lastErrorMessage = localizedDescription(for: .noSupportedSMCKey)
                store.setEnabled(false)
                onStateChange?()
                return
            }
            // Enabling always starts in holdAtLimit — the core behavior is
            // "don't auto-charge; user must explicitly resume."
            store.setMode(.holdAtLimit)
            startActiveMonitoring()
            applyCurrentMode(reason: "user-enable")
        } else {
            store.setMode(.holdAtLimit)
            _ = restoreUnrestrictedCharging(reason: "user-disable", requireInstalledHelper: false)
            stopActiveMonitoring()
            lastErrorMessage = nil
        }
        onStateChange?()
    }

    private func handleLimitChange(_ percent: Int) {
        store.setLimitPercent(percent)
        // Changing the limit always returns to holdAtLimit. This matches the
        // user's design: the act of setting a limit means "stop charging at
        // this level; don't auto-resume."
        if store.isEnabled {
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "limit-change")
        }
        onStateChange?()
    }

    private func handleInvokeAction(_ controlID: String) {
        switch controlID {
        case ControlID.enableAction:
            handleEnableToggle(!store.isEnabled)

        case ControlID.chargeAction:
            handleChargeActionTap()

        case ControlID.dischargeAction:
            handleDischargeActionTap()

        case ControlID.manageSettings:
            // The host intercepts this action and opens the plugin's settings
            // configuration page. No-op here.
            break

        default:
            break
        }
    }

    private func handleChargeActionTap() {
        guard store.isEnabled else { return }
        switch store.mode {
        case .holdAtLimit:
            // User explicitly asks to start charging. Move to .charging; the
            // monitoring loop will revert to .holdAtLimit when the battery
            // reaches the limit.
            store.setMode(.charging)
            applyCurrentMode(reason: "user-resume")
        case .charging:
            // User asks to stop charging — return to .holdAtLimit.
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "user-stop-charging")
        case .discharging:
            // Treat as "stop discharging and hold at current level."
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "user-stop-discharge-via-charge")
        }
        onStateChange?()
    }

    private func handleDischargeActionTap() {
        guard store.isEnabled, capabilities.canForceDischarge else { return }
        switch store.mode {
        case .discharging:
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "user-stop-discharge")
        default:
            store.setMode(.discharging)
            applyCurrentMode(reason: "user-start-discharge")
        }
        onStateChange?()
    }

    // MARK: - State Application

    private func applyCurrentMode(reason: String) {
        guard store.isEnabled else {
            _ = restoreUnrestrictedCharging(reason: reason, requireInstalledHelper: false)
            return
        }

        switch store.mode {
        case .holdAtLimit:
            _ = setForceDischarge(false)
            if let err = inhibitCharging(limitPercent: store.limitPercent) {
                lastErrorMessage = localizedDescription(for: err)
                BatteryChargeLimitLog.plugin.error("inhibit failed (\(reason, privacy: .public)): \(self.localizedDescription(for: err), privacy: .public)")
            } else {
                lastErrorMessage = nil
            }

        case .charging:
            if let err = restoreUnrestrictedCharging(reason: reason, requireInstalledHelper: false) {
                lastErrorMessage = localizedDescription(for: err)
                BatteryChargeLimitLog.plugin.error("resume failed (\(reason, privacy: .public)): \(self.localizedDescription(for: err), privacy: .public)")
            } else {
                lastErrorMessage = nil
            }

        case .discharging:
            // Force-discharge implies the inhibit keys must also be set so
            // the adapter doesn't fight us by charging back up.
            if let err = inhibitCharging(limitPercent: store.limitPercent) {
                BatteryChargeLimitLog.plugin.error("inhibit-for-discharge failed: \(self.localizedDescription(for: err), privacy: .public)")
            }
            if let err = setForceDischarge(true) {
                lastErrorMessage = localizedDescription(for: err)
                BatteryChargeLimitLog.plugin.error("force-discharge failed (\(reason, privacy: .public)): \(self.localizedDescription(for: err), privacy: .public)")
            } else {
                lastErrorMessage = nil
            }
        }
        onStateChange?()
    }

    /// Automatic mode transitions driven by battery level changes.
    /// Crucially, we DO NOT transition out of `.holdAtLimit` here — the user's
    /// design choice is that "below limit, charging stays off until manual resume."
    private func evaluateAutoTransitions() {
        guard store.isEnabled, let level = batterySnapshot.levelPercent else { return }

        switch store.mode {
        case .charging where level >= store.limitPercent:
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "auto-reached-limit")

        case .discharging where level <= store.limitPercent:
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "auto-discharged-to-limit")

        case .holdAtLimit:
            // Re-assert the inhibit periodically — firmware can reset SMC
            // keys across sleep, adapter unplug/replug, and rare hibernation
            // events. Cheap to re-issue.
            if batterySnapshot.state == .charging {
                applyCurrentMode(reason: "re-assert-inhibit")
            }

        default:
            break
        }
    }

    // MARK: - Monitoring

    private func startActiveMonitoring() {
        startMonitoring()
        registerSleepWakeObservers()
    }

    private func stopActiveMonitoring() {
        unregisterSleepWakeObservers()
        stopMonitoring()
    }

    private func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.batterySnapshot = self?.reader.readSnapshot() ?? .empty
                self?.evaluateAutoTransitions()
                self?.evaluateHealthProtections()
                self?.onStateChange?()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func registerSleepWakeObservers() {
        guard sleepObserver == nil, wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWillSleep() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemDidWake() }
        }
    }

    private func unregisterSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { center.removeObserver(obs) }
        if let obs = wakeObserver { center.removeObserver(obs) }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func handleSystemWillSleep() {
        guard store.isEnabled else { return }
        BatteryChargeLimitLog.plugin.info("System will sleep — current mode: \(String(describing: self.store.mode), privacy: .public)")
        guard store.inhibitChargingDuringSleep else { return }
        applyCurrentMode(reason: "will-sleep-inhibit")
    }

    private func handleSystemDidWake() {
        guard store.isEnabled else { return }
        batterySnapshot = reader.readSnapshot()
        applyCurrentMode(reason: "did-wake")
        evaluateHealthProtections()
        BatteryChargeLimitLog.plugin.info("System did wake — re-asserted mode: \(String(describing: self.store.mode), privacy: .public)")
    }

    private func evaluateHealthProtections() {
        evaluateFloorReminder()
        evaluateThermalProtection()
    }

    private func evaluateFloorReminder() {
        guard store.isEnabled, store.floorReminderEnabled else {
            didNotifyFloorReminder = false
            return
        }
        guard batterySnapshot.hasBattery,
              !batterySnapshot.isOnAdapter,
              let level = batterySnapshot.levelPercent
        else {
            if batterySnapshot.isOnAdapter {
                didNotifyFloorReminder = false
            }
            return
        }

        if level > store.floorPercent {
            didNotifyFloorReminder = false
            return
        }

        guard !didNotifyFloorReminder else { return }
        didNotifyFloorReminder = true
        notifier.notifyFloorReminder(level: level, floor: store.floorPercent, localization: localization)
    }

    private func evaluateThermalProtection() {
        guard store.isEnabled, store.thermalProtectionEnabled else {
            didNotifyThermalThisSession = false
            return
        }
        guard let temperature = batterySnapshot.temperatureCelsius else { return }
        let threshold = Double(store.thermalThresholdCelsius)
        guard temperature >= threshold else {
            didNotifyThermalThisSession = false
            return
        }

        if store.mode == .charging || batterySnapshot.state == .charging {
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "thermal-protection")
        }

        guard !didNotifyThermalThisSession, !store.isThermalReminderMutedToday else { return }
        didNotifyThermalThisSession = true
        store.muteThermalReminderForToday()
        notifier.notifyThermalProtection(
            temperature: temperature,
            threshold: store.thermalThresholdCelsius,
            localization: localization
        )
    }

    // MARK: - Panel Builder

    private var panelSubtitle: String {
        guard batterySnapshot.hasBattery else {
            return localization.string("panel.subtitle.noBattery", defaultValue: "未检测到电池")
        }
        let level = batterySnapshot.levelPercent ?? 0

        if !store.isEnabled {
            return localization.format("panel.subtitle.disabled", defaultValue: "未启用 · %d%%", level)
        }

        var suffixParts: [String] = []
        if let health = batterySnapshot.healthPercent {
            suffixParts.append(localization.format("panel.subtitle.health", defaultValue: "健康 %d%%", health))
        }
        if let cycles = batterySnapshot.cycleCount {
            suffixParts.append(localization.format("panel.subtitle.cycles", defaultValue: "%d 循环", cycles))
        }
        let infoSuffix = suffixParts.isEmpty ? "" : " · " + suffixParts.joined(separator: " · ")

        let limit = store.limitPercent
        switch store.mode {
        case .holdAtLimit:
            if level >= limit {
                return localization.format(
                    "panel.subtitle.limitReached",
                    defaultValue: "已达上限 · %d%% / %d%%%@",
                    level,
                    limit,
                    infoSuffix
                )
            }
            return localization.format(
                "panel.subtitle.chargingStopped",
                defaultValue: "已停止充电 · %d%% / %d%%%@",
                level,
                limit,
                infoSuffix
            )
        case .charging:
            return localization.format("panel.subtitle.charging", defaultValue: "充电中 · %d%% → %d%%", level, limit)
        case .discharging:
            return localization.format("panel.subtitle.discharging", defaultValue: "放电中 · %d%% → %d%%", level, limit)
        }
    }

    private func buildDetail() -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []

        // 1. Enable/disable toggle as the first row.
        let enableTitle = store.isEnabled
            ? localization.string("panel.action.disable", defaultValue: "停用充电上限")
            : localization.string("panel.action.enable", defaultValue: "启用充电上限")
        let enableIcon = store.isEnabled ? "checkmark.circle.fill" : "circle"
        controls.append(PluginPanelControl(
            id: ControlID.enableAction,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: enableTitle,
            actionIconSystemName: enableIcon,
            isEnabled: writer.isHelperAvailable
        ))

        if store.isEnabled {
            // 2. Limit slider — shown only when enabled
            controls.append(PluginPanelControl(
                id: ControlID.limitSlider,
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: localization.string("panel.section.limit", defaultValue: "充电上限"),
                sliderValue: Double(store.limitPercent),
                sliderBounds: Double(BatteryChargeLimits.minimumPercent)...Double(BatteryChargeLimits.maximumPercent),
                sliderStep: Double(BatteryChargeLimits.percentStep),
                valueLabel: "\(store.limitPercent)%",
                isEnabled: true
            ))

            // 3. Charge/stop button — context-sensitive title and icon
            let chargeTitle: String
            let chargeIcon: String
            switch store.mode {
            case .holdAtLimit:
                chargeTitle = localization.string("panel.action.startCharging", defaultValue: "开始充电")
                chargeIcon = "bolt.fill"
            case .charging:
                chargeTitle = localization.string("panel.action.stopCharging", defaultValue: "停止充电")
                chargeIcon = "bolt.slash.fill"
            case .discharging:
                chargeTitle = localization.string("panel.action.stopDischarging", defaultValue: "停止放电")
                chargeIcon = "stop.fill"
            }
            controls.append(PluginPanelControl(
                id: ControlID.chargeAction,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: chargeTitle,
                actionIconSystemName: chargeIcon,
                showsLeadingDivider: true,
                isEnabled: true
            ))

            // 4. Force-discharge button — only when supported AND battery is
            //    currently above the limit (otherwise it's a no-op).
            if capabilities.canForceDischarge,
               let level = batterySnapshot.levelPercent,
               level > store.limitPercent
            {
                let title = store.mode == .discharging
                    ? localization.string("panel.action.stopDischarging", defaultValue: "停止放电")
                    : localization.format(
                        "panel.action.dischargeToLimit",
                        defaultValue: "强制放电至 %d%%",
                        store.limitPercent
                    )
                controls.append(PluginPanelControl(
                    id: ControlID.dischargeAction,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    actionTitle: title,
                    actionIconSystemName: "minus.circle",
                    isEnabled: true
                ))
            }
        }

        // 5. Open settings page
        controls.append(PluginPanelControl(
            id: ControlID.manageSettings,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.settings", defaultValue: "设置…"),
            actionIconSystemName: "slider.horizontal.3",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        ))

        // 6. Missing helper warning
        if !writer.isHelperAvailable {
            controls.append(PluginPanelControl(
                id: ControlID.missingHelper,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("panel.action.missingHelper", defaultValue: "电池控制组件缺失"),
                actionIconSystemName: "exclamationmark.triangle",
                actionBehavior: .dismissBeforeHandling,
                showsLeadingDivider: true,
                isEnabled: false
            ))
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func localizedDescription(for error: BatteryChargeWriteError) -> String {
        error.localizedDescription(localization: localization)
    }

    @discardableResult
    private func inhibitCharging(limitPercent: Int) -> BatteryChargeWriteError? {
        let error = writer.inhibitCharging(limitPercent: limitPercent)
        markCleanupRequiredIfNeeded(after: error)
        return error
    }

    @discardableResult
    private func setForceDischarge(_ on: Bool) -> BatteryChargeWriteError? {
        let error = writer.setForceDischarge(on)
        if on {
            markCleanupRequiredIfNeeded(after: error)
        }
        return error
    }

    private func markCleanupRequiredIfNeeded(after error: BatteryChargeWriteError?) {
        if error == nil || error?.mayHaveChangedSMCState == true {
            requiresSMCCleanup = true
        }
    }

    private func restoreUnrestrictedChargingIfNeeded(reason: String, requireInstalledHelper: Bool) {
        guard requiresSMCCleanup else {
            BatteryChargeLimitLog.plugin.info("Skipped SMC charge cleanup for \(reason, privacy: .public); no active charge-control state")
            return
        }

        _ = restoreUnrestrictedCharging(reason: reason, requireInstalledHelper: requireInstalledHelper)
    }

    @discardableResult
    private func restoreUnrestrictedCharging(
        reason: String,
        requireInstalledHelper: Bool
    ) -> BatteryChargeWriteError? {
        guard !requireInstalledHelper || writer.isInstalledHelperAvailable else {
            BatteryChargeLimitLog.plugin.info("Skipped SMC charge cleanup for \(reason, privacy: .public); helper is not installed")
            return nil
        }

        let dischargeError = writer.setForceDischarge(false)
        let resumeError = writer.resumeCharging()

        if resumeError == nil && dischargeError == nil {
            requiresSMCCleanup = false
            BatteryChargeLimitLog.plugin.info("Cleared SMC charge-control state for \(reason, privacy: .public)")
            return nil
        } else {
            BatteryChargeLimitLog.plugin.error("Failed to fully clear SMC charge-control state for \(reason, privacy: .public)")
            return dischargeError ?? resumeError
        }
    }
}

private extension BatteryChargeWriteError {
    var mayHaveChangedSMCState: Bool {
        if case .writeFailed = self {
            return true
        }

        return false
    }
}
