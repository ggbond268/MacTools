import AppKit
import SwiftUI
import MacToolsPluginKit

public final class ActivityBarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ActivityBarPluginProvider(context: context)
    }
}

@MainActor
private struct ActivityBarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            ActivityBarPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class ActivityBarPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel, PluginActionProviding {
    private enum ActionID {
        static let setTrackingEnabled = "set-tracking-enabled"
        static let resetToday = "reset-today"
    }

    private struct SettingsStatus {
        let text: String
        let systemImage: String
        let tone: PluginStatusTone
    }
    private enum ControlID {
        static let trackingEnabled = "tracking-enabled"
        static let installHooks = "install-hooks"
        static let uninstallHooks = "uninstall-hooks"
        static let resetToday = "reset-today"
        static let openInputMonitoring = "open-input-monitoring"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var descriptor: PluginComponentDescriptor {
        PluginComponentDescriptor(
            span: PluginComponentSpan(width: 4, height: dashboardSpanHeight)!
        )
    }

    private let localization: PluginLocalization
    private let controller: ActivityBarController
    private var isExpanded = false
    private var dashboardSpanHeight = PluginComponentPanelLayoutMetrics.default.heightSpan(
        closestToOriginalSpanHeight: 9
    )

    var onStateChange: (() -> Void)? {
        didSet {
            controller.onStateChange = onStateChange
        }
    }
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(
        context: PluginRuntimeContext,
        controller: ActivityBarController? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: ActivityBarController.pluginID,
            title: localization.string("metadata.title", defaultValue: "活动统计"),
            iconName: "chart.bar.xaxis",
            iconTint: Color(nsColor: .systemGreen),
            order: 18,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "统计输入、前台应用使用时长和 AI 编程活动"
            )
        )
        self.controller = controller ?? ActivityBarController(context: context, localization: localization)
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: controller.panelSubtitle,
            isOn: controller.isTrackingEnabled,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? panelDetail : nil,
            errorMessage: controller.lastErrorMessage
        )
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: controller.componentSubtitle,
            isActive: controller.isTrackingEnabled || controller.isHookListenerRunning,
            isEnabled: true,
            isVisible: true,
            errorMessage: controller.lastErrorMessage
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "monitoring",
                    title: localization.string("settings.section.status", defaultValue: "状态"),
                    systemImage: "waveform.path.ecg",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.openInputMonitoring,
                            title: localization.string("settings.inputMonitoring.title", defaultValue: "输入监控"),
                            description: localization.string(
                                "settings.inputMonitoring.description",
                                defaultValue: "用于统计键盘、鼠标点击和滚动事件。"
                            ),
                            systemImage: "keyboard",
                            help: controller.inputMonitoringFootnote,
                            control: .status(
                                text: inputMonitoringSettingsStatus.text,
                                systemImage: inputMonitoringSettingsStatus.systemImage,
                                tone: inputMonitoringSettingsStatus.tone,
                                actionTitle: localization.string(
                                    "settings.inputMonitoring.button",
                                    defaultValue: "打开系统设置"
                                )
                            )
                        ),
                        PluginSettingsRow(
                            id: hookActionControlID,
                            title: localization.string("settings.aiHooks.title", defaultValue: "AI 工具 Hook"),
                            description: localization.string(
                                "settings.aiHooks.description",
                                defaultValue: "记录 Claude Code、Cursor 和 Codex 的提示、工具调用与执行时长。"
                            ),
                            systemImage: "terminal",
                            help: controller.hookActionFootnote,
                            control: .status(
                                text: hookSettingsStatus.text,
                                systemImage: hookSettingsStatus.systemImage,
                                tone: hookSettingsStatus.tone,
                                actionTitle: hookActionButtonTitle
                            )
                        )
                    ]
                )
            ]
        )
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setTrackingEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string(
                            "panel.action.trackingEnabled",
                            defaultValue: "活动统计"
                        ),
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.resetToday),
                title: localization.string("panel.action.resetToday", defaultValue: "清空今日统计"),
                description: metadata.defaultDescription,
                keywords: [metadata.title, localization.string("panel.action.resetToday", defaultValue: "清空今日统计")],
                systemImage: "arrow.counterclockwise",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("panel.action.resetToday", defaultValue: "清空今日统计"),
                    message: metadata.defaultDescription,
                    confirmButtonTitle: localization.string("panel.action.resetToday", defaultValue: "清空今日统计")
                ),
                externalInvocationPolicy: .unavailable,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: trackingActionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("status.running", defaultValue: "运行中"))"
            ),
            ActionCatalogEntry(
                reference: trackingActionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("status.disabled", defaultValue: "未开启"))"
            ),
            ActionCatalogEntry(
                reference: ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.resetToday)),
                title: localization.string("panel.action.resetToday", defaultValue: "清空今日统计")
            ),
        ]
    }

    func activate(context: PluginRuntimeContext) {
        controller.activate(context: context)
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.deactivate(reason: reason)
    }

    func refresh() {
        controller.refresh()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            controller.setTrackingEnabled(isEnabled)
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .invokeAction(controlID):
            handleAction(controlID: controlID)
        case .setSelection, .setNavigationSelection,
             .clearNavigationSelection, .setDate, .setSlider:
            return
        }
    }

    func makeView(context _: PluginComponentContext) -> AnyView {
        AnyView(
            ActivityBarComponentView(
                controller: controller,
                localization: localization,
                onContentHeightChange: { [weak self] height in
                    self?.dashboardContentHeightDidChange(height)
                }
            )
        )
    }

    func dashboardContentHeightDidChange(_ contentHeight: CGFloat) {
        guard contentHeight.isFinite, contentHeight > 0 else {
            return
        }

        let resolvedSpanHeight = PluginComponentPanelLayoutMetrics.default.heightSpan(
            fittingContentHeight: contentHeight
        )
        guard resolvedSpanHeight != dashboardSpanHeight else {
            return
        }

        dashboardSpanHeight = resolvedSpanHeight
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .invoke(controlID) = action else { return }
        handleAction(controlID: controlID)
    }

    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        switch invocation.reference.key.actionID {
        case ActionID.setTrackingEnabled:
            guard case let .boolean(enabled)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else {
                    return .failed(message: PluginKitLocalization.actionUnavailable)
                }
                return self.actionResult(for: self.controller.setTrackingEnabled(enabled))
            }
        case ActionID.resetToday:
            return ActionExecutionHandle { [weak self] in
                guard let self else {
                    return .failed(message: PluginKitLocalization.actionUnavailable)
                }
                return self.actionResult(for: self.controller.resetToday())
            }
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
    }

    private func actionResult(
        for mutation: ActivityBarPersistenceMutationResult
    ) -> ActionExecutionResult {
        mutation == .committed
            ? .succeeded()
            : .failed(message: PluginKitLocalization.actionFailed)
    }

    private var panelDetail: PluginPanelDetail {
        let trackingControl = PluginPanelControl(
            id: ControlID.trackingEnabled,
            kind: .switchRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.trackingEnabled", defaultValue: "活动统计"),
            actionIconSystemName: "chart.bar.xaxis",
            isEnabled: true
        )

        let openSettingsControl = PluginPanelControl(
            id: ControlID.openInputMonitoring,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openInputMonitoring", defaultValue: "打开输入监控设置"),
            actionIconSystemName: "keyboard.badge.eye",
            isEnabled: true
        )

        let hookActionControl = PluginPanelControl(
            id: hookActionControlID,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: hookActionPanelTitle,
            actionIconSystemName: controller.areHooksInstalled ? "trash" : "terminal",
            isEnabled: true
        )

        let resetControl = PluginPanelControl(
            id: ControlID.resetToday,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.resetToday", defaultValue: "清空今日统计"),
            actionIconSystemName: "arrow.counterclockwise",
            showsLeadingDivider: true,
            isEnabled: true
        )

        return PluginPanelDetail(
            primaryControls: [trackingControl, openSettingsControl, hookActionControl, resetControl],
            secondaryPanel: nil
        )
    }

    private func trackingActionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setTrackingEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var hookActionControlID: String {
        controller.areHooksInstalled ? ControlID.uninstallHooks : ControlID.installHooks
    }

    private var hookActionButtonTitle: String {
        if controller.areHooksInstalled {
            return localization.string("settings.aiHooks.uninstallButton", defaultValue: "卸载 Hook")
        }

        return localization.string("settings.aiHooks.button", defaultValue: "安装或更新 Hook")
    }

    private var hookActionPanelTitle: String {
        if controller.areHooksInstalled {
            return localization.string("panel.action.uninstallHooks", defaultValue: "卸载 AI Hook")
        }

        return localization.string("panel.action.installHooks", defaultValue: "安装或更新 AI Hook")
    }

    private var inputMonitoringSettingsStatus: SettingsStatus {
        switch controller.monitorStatus {
        case .running:
            return SettingsStatus(
                text: localization.string("status.running", defaultValue: "运行中"),
                systemImage: "checkmark.circle.fill",
                tone: .positive
            )
        case .inputMonitoringDenied:
            return SettingsStatus(
                text: localization.string("status.permissionRequired", defaultValue: "需要授权"),
                systemImage: "exclamationmark.triangle.fill",
                tone: .caution
            )
        case .idle:
            return SettingsStatus(
                text: localization.string("status.disabled", defaultValue: "未开启"),
                systemImage: "pause.circle",
                tone: .neutral
            )
        }
    }

    private var hookSettingsStatus: SettingsStatus {
        switch controller.hookInstallState {
        case .installed:
            if controller.isHookListenerRunning {
                return SettingsStatus(
                    text: localization.string("hook.status.listening", defaultValue: "监听中"),
                    systemImage: "checkmark.circle.fill",
                    tone: .positive
                )
            }

            return SettingsStatus(
                text: localization.string("hook.status.installed", defaultValue: "已安装"),
                systemImage: "checkmark.circle.fill",
                tone: .positive
            )
        case .failed:
            return SettingsStatus(
                text: localization.string("hook.status.installFailed", defaultValue: "安装失败"),
                systemImage: "exclamationmark.triangle.fill",
                tone: .caution
            )
        case .notInstalled:
            return SettingsStatus(
                text: localization.string("hook.status.notInstalled", defaultValue: "未安装"),
                systemImage: "terminal",
                tone: .neutral
            )
        }
    }

    private func handleAction(controlID: String) {
        switch controlID {
        case ControlID.installHooks:
            controller.installHooks()
        case ControlID.uninstallHooks:
            controller.uninstallHooks()
        case ControlID.resetToday:
            controller.resetToday()
        case ControlID.openInputMonitoring:
            controller.openInputMonitoringSettings()
        default:
            break
        }
    }
}
