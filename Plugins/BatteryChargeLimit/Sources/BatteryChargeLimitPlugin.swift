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
        [BatteryChargeLimitPlugin(context: context)]
    }
}

// MARK: - Control IDs

private enum ControlID {
    static let enableAction    = "battery-enable-action"
    static let limitSlider     = "battery-limit-slider"
    static let chargeAction    = "battery-charge-action"
    static let dischargeAction = "battery-discharge-action"
    static let manageSettings  = "battery-manage-settings"
    static let missingHelper   = "battery-missing-helper"
}

// MARK: - Plugin

@MainActor
final class BatteryChargeLimitPlugin: MacToolsPlugin, PluginPrimaryPanel {

    // MARK: Metadata

    let metadata = PluginMetadata(
        id: "battery-charge-limit",
        title: "电池充电上限",
        iconName: "battery.100.bolt",
        iconTint: Color(nsColor: .systemGreen),
        order: 48,
        defaultDescription: "限制电池充电至指定上限"
    )

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
    private let reader: any BatteryChargeLimitReading
    private let writer: any BatteryChargeLimitWriting

    private var isExpanded = false
    private var batterySnapshot: BatterySnapshot = .empty
    private var capabilities: BatterySMCCapabilities = .none
    private var lastErrorMessage: String?
    private var monitoringTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "battery-charge-limit"),
        reader: any BatteryChargeLimitReading = BatteryChargeLimitReader(),
        writer: (any BatteryChargeLimitWriting)? = nil
    ) {
        self.store = BatteryChargeLimitStore(storage: context.storage)
        self.reader = reader
        self.writer = writer ?? BatteryChargeLimitWriter(resourceBundle: context.resourceBundle)
    }

    // MARK: - Lifecycle

    func activate(context: PluginRuntimeContext) {
        batterySnapshot = reader.readSnapshot()
        startMonitoring()
        registerSleepWakeObservers()

        // Re-assert the persisted mode after app restart. SMC keys can be
        // reset by firmware across sleep/hibernation, so on launch we
        // re-apply whatever the user last had configured.
        if store.isEnabled {
            // 重新探测能力：capabilities 之前只在 handleEnableToggle 里赋值，重启（持久化
            // enabled）时不经过那条路径，会停在 .none，导致强制放电功能与设置项静默消失。
            // probeCapabilities() 是带缓存的纯 SMC 读，无副作用。
            capabilities = writer.probeCapabilities()
            applyCurrentMode(reason: "activate")
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        unregisterSleepWakeObservers()
        stopMonitoring()
        // 强制放电(CH0I)在没有监控任务时持续放电，任何停用场景下都不安全，必须无条件停止。
        // 尤其热更新(.updating) requiresStateCleanup==false 且新版不在进程内重新激活，
        // 否则会让电池在插电状态下被持续放空。充电上限(inhibit)则只在真正清理时解除——
        // 热更新期间保留限制是期望行为。
        _ = writer.setForceDischarge(false)
        if reason.requiresStateCleanup {
            // Restore unrestricted charging so the user isn't left with the
            // SMC stuck in inhibit after disabling/uninstalling the plugin.
            _ = writer.resumeCharging()
            BatteryChargeLimitLog.plugin.info("Deactivated (\(String(describing: reason), privacy: .public)) — cleared SMC charge inhibit")
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
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [self] _ in
            BatteryChargeLimitSettingsView(
                store: self.store,
                capabilities: self.capabilities,
                snapshot: self.batterySnapshot
            )
        }
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
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - User Actions

    private func handleEnableToggle(_ value: Bool) {
        store.setEnabled(value)
        if value {
            // Probe capabilities lazily — the helper install prompt happens
            // on first call. Surface a clear error if the hardware can't be
            // inhibited.
            capabilities = writer.probeCapabilities()
            if !capabilities.canInhibit && writer.isHelperAvailable {
                lastErrorMessage = BatteryChargeWriteError.noSupportedSMCKey.errorDescription
                store.setEnabled(false)
                onStateChange?()
                return
            }
            // Enabling always starts in holdAtLimit — the core behavior is
            // "don't auto-charge; user must explicitly resume."
            store.setMode(.holdAtLimit)
            applyCurrentMode(reason: "user-enable")
        } else {
            store.setMode(.holdAtLimit)
            _ = writer.setForceDischarge(false)
            _ = writer.resumeCharging()
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
            _ = writer.setForceDischarge(false)
            _ = writer.resumeCharging()
            return
        }

        switch store.mode {
        case .holdAtLimit:
            _ = writer.setForceDischarge(false)
            if let err = writer.inhibitCharging(limitPercent: store.limitPercent) {
                lastErrorMessage = err.errorDescription
                BatteryChargeLimitLog.plugin.error("inhibit failed (\(reason, privacy: .public)): \(err.localizedDescription, privacy: .public)")
            } else {
                lastErrorMessage = nil
            }

        case .charging:
            _ = writer.setForceDischarge(false)
            if let err = writer.resumeCharging() {
                lastErrorMessage = err.errorDescription
                BatteryChargeLimitLog.plugin.error("resume failed (\(reason, privacy: .public)): \(err.localizedDescription, privacy: .public)")
            } else {
                lastErrorMessage = nil
            }

        case .discharging:
            // Force-discharge implies the inhibit keys must also be set so
            // the adapter doesn't fight us by charging back up.
            if let err = writer.inhibitCharging(limitPercent: store.limitPercent) {
                BatteryChargeLimitLog.plugin.error("inhibit-for-discharge failed: \(err.localizedDescription, privacy: .public)")
            }
            if let err = writer.setForceDischarge(true) {
                lastErrorMessage = err.errorDescription
                BatteryChargeLimitLog.plugin.error("force-discharge failed (\(reason, privacy: .public)): \(err.localizedDescription, privacy: .public)")
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

    private func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.batterySnapshot = self?.reader.readSnapshot() ?? .empty
                self?.evaluateAutoTransitions()
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
        // Keep the inhibit in place on sleep so the Mac doesn't quietly
        // charge past the limit while the user is away.
        guard store.isEnabled else { return }
        BatteryChargeLimitLog.plugin.info("System will sleep — current mode: \(String(describing: self.store.mode), privacy: .public)")
    }

    private func handleSystemDidWake() {
        guard store.isEnabled else { return }
        batterySnapshot = reader.readSnapshot()
        applyCurrentMode(reason: "did-wake")
        BatteryChargeLimitLog.plugin.info("System did wake — re-asserted mode: \(String(describing: self.store.mode), privacy: .public)")
    }

    // MARK: - Panel Builder

    private var panelSubtitle: String {
        guard batterySnapshot.hasBattery else { return "未检测到电池" }
        let level = batterySnapshot.levelPercent ?? 0

        if !store.isEnabled {
            return "未启用 · \(level)%"
        }

        let limit = store.limitPercent
        switch store.mode {
        case .holdAtLimit:
            if level >= limit {
                return "已达上限 · \(level)% / \(limit)%"
            }
            return "已停止充电 · \(level)% / \(limit)%"
        case .charging:
            return "充电中 · \(level)% → \(limit)%"
        case .discharging:
            return "放电中 · \(level)% → \(limit)%"
        }
    }

    private func buildDetail() -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []

        // 1. Enable/disable toggle as the first row.
        let enableTitle = store.isEnabled ? "停用充电上限" : "启用充电上限"
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
                sectionTitle: "充电上限",
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
                chargeTitle = "开始充电"
                chargeIcon = "bolt.fill"
            case .charging:
                chargeTitle = "停止充电"
                chargeIcon = "bolt.slash.fill"
            case .discharging:
                chargeTitle = "停止放电"
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
                let title = store.mode == .discharging ? "停止放电" : "强制放电至 \(store.limitPercent)%"
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
            actionTitle: "设置…",
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
                actionTitle: "电池控制组件缺失",
                actionIconSystemName: "exclamationmark.triangle",
                actionBehavior: .dismissBeforeHandling,
                showsLeadingDivider: true,
                isEnabled: false
            ))
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }
}
