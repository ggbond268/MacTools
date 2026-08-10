import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class WindowLayoutPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        WindowLayoutPluginProvider(context: context)
    }
}

@MainActor
private struct WindowLayoutPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            WindowLayoutPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class WindowLayoutPlugin: MacToolsPlugin, PluginPrimaryPanel, AccessibilityPermissionRefreshing {
    private enum Constants {
        static let pluginID = "window-layout"
        static let pluginOrder = 65
        static let accessibilityPermissionID = "accessibility"
        static let insetSettingsID = "almost-maximize-inset"
        static let shortcutGroupID = "window-layout-shortcuts"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    let store: WindowLayoutStore
    private let localization: PluginLocalization
    private let applicator: any WindowLayoutApplying
    private let history: WindowLayoutHistory
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool

    private var isExpanded = false
    private var isAccessibilityGranted: Bool
    private var lastErrorMessage: String?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: Constants.pluginID),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        applicator: (any WindowLayoutApplying)? = nil,
        history: WindowLayoutHistory = WindowLayoutHistory(),
        accessibilityTrusted: @escaping @MainActor () -> Bool = WindowLayoutAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = WindowLayoutAccessibilityCheck.requestTrust(prompt:)
    ) {
        self.localization = localization
        self.store = WindowLayoutStore(storage: context.storage)
        self.applicator = applicator ?? AXWindowLayoutApplicator()
        self.history = history
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isAccessibilityGranted = accessibilityTrusted()
        self.metadata = PluginMetadata(
            id: Constants.pluginID,
            title: localization.string("metadata.title", defaultValue: "窗口布局"),
            iconName: "rectangle.split.3x3",
            iconTint: Color(nsColor: .systemTeal),
            order: Constants.pluginOrder,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "调整前台窗口大小与位置"
            )
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: Constants.accessibilityPermissionID,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于调整其他应用窗口的大小与位置。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        WindowLayoutAction.allCases.map { action in
            PluginShortcutDefinition(
                id: action.rawValue,
                title: title(for: action),
                description: localization.format(
                    "shortcut.descriptionFormat",
                    defaultValue: "将前台窗口设为%@。",
                    title(for: action)
                ),
                actionID: action.rawValue,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: Constants.shortcutGroupID,
                settingsGroupTitle: localization.string(
                    "shortcut.settingsGroupTitle",
                    defaultValue: "窗口布局快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.settingsGroupDescription",
                    defaultValue: "为各布局预设绑定全局快捷键。"
                ),
                settingsControlSystemImage: systemImage(for: action)
            )
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "almost-maximize",
                    title: localization.string("settings.inset.title", defaultValue: "接近最大化"),
                    systemImage: "rectangle.inset.filled",
                    rows: [
                        PluginSettingsRow(
                            id: Constants.insetSettingsID,
                            title: localization.string("settings.inset.rowTitle", defaultValue: "边距"),
                            description: localization.string(
                                "settings.inset.description",
                                defaultValue: "接近最大化时相对屏幕可视区域的内缩边距。"
                            ),
                            systemImage: "arrow.up.left.and.arrow.down.right",
                            control: .slider(
                                value: Double(store.almostMaximizeInset),
                                range: Double(WindowLayoutStore.insetRange.lowerBound)...Double(WindowLayoutStore.insetRange.upperBound),
                                step: 1,
                                valueFormat: PluginSettingsSliderValueFormat(suffix: " pt")
                            )
                        ),
                    ]
                ),
            ]
        )
    }

    var primaryPanelState: PluginPanelState {
        let subtitle: String
        if !isAccessibilityGranted {
            subtitle = localization.string(
                "panel.subtitle.needsAccessibility",
                defaultValue: "需要辅助功能权限"
            )
        } else {
            subtitle = localization.string(
                "panel.subtitle.ready",
                defaultValue: "调整前台窗口布局"
            )
        }

        return PluginPanelState(
            subtitle: subtitle,
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail() : nil,
            errorMessage: lastErrorMessage
        )
    }

    func refresh() {
        refreshAccessibilityPermission()
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup {
            history.removeAll()
            lastErrorMessage = nil
        }
    }

    func refreshAccessibilityPermission() {
        let granted = accessibilityTrusted()
        let changed = isAccessibilityGranted != granted
        isAccessibilityGranted = granted
        if changed {
            if !granted {
                lastErrorMessage = localization.string(
                    "error.accessibilityRequired",
                    defaultValue: "需要辅助功能权限"
                )
            } else if lastErrorMessage != nil {
                lastErrorMessage = nil
            }
            onStateChange?()
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == Constants.accessibilityPermissionID else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "授权后即可调整窗口布局。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == Constants.accessibilityPermissionID else {
            return
        }
        _ = requestAccessibilityTrust(true)
        refreshAccessibilityPermission()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setNumber(controlID, value, phase) = action,
              controlID == Constants.insetSettingsID,
              phase == .committed
        else {
            return
        }
        store.setAlmostMaximizeInset(CGFloat(value))
        onStateChange?()
    }

    func handleShortcutAction(id: String) {
        guard let action = WindowLayoutAction(rawValue: id) else {
            return
        }
        apply(action)
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if !expanded {
                lastErrorMessage = nil
            }
            onStateChange?()

        case let .invokeAction(controlID):
            guard let layoutAction = WindowLayoutAction(rawValue: controlID) else {
                return
            }
            apply(layoutAction)

        case .setSwitch, .setSelection, .setNavigationSelection, .clearNavigationSelection, .setDate, .setSlider:
            break
        }
    }

    func apply(_ action: WindowLayoutAction) {
        guard accessibilityTrusted() else {
            isAccessibilityGranted = false
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "需要辅助功能权限"
            )
            requestPermissionGuidance?(Constants.accessibilityPermissionID)
            onStateChange?()
            return
        }

        do {
            if action == .restore {
                let target = try applicator.resolveFrontmostResizableWindow()
                guard let previous = history.frame(for: target.key) else {
                    throw WindowLayoutApplyError.nothingToRestore
                }
                try applicator.setFrame(previous, for: target.key)
                history.clear(target.key)
                lastErrorMessage = nil
                onStateChange?()
                return
            }

            let target = try applicator.resolveFrontmostResizableWindow()
            history.snapshotIfNeeded(key: target.key, frame: target.frame)
            let next = WindowLayoutGeometry.targetFrame(
                action: action,
                visibleFrame: target.visibleFrame,
                currentFrame: target.frame,
                inset: store.almostMaximizeInset
            )
            try applicator.setFrame(next, for: target.key)
            lastErrorMessage = nil
            onStateChange?()
        } catch {
            lastErrorMessage = userMessage(for: error)
            onStateChange?()
        }
    }

    private func buildDetail() -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []
        controls.append(contentsOf: actionRows(
            [
                .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf,
            ],
            sectionTitle: localization.string("panel.section.halves", defaultValue: "半屏")
        ))
        controls.append(contentsOf: actionRows(
            [
                .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
            ],
            sectionTitle: localization.string("panel.section.thirds", defaultValue: "三分")
        ))
        controls.append(contentsOf: actionRows(
            [
                .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
            ],
            sectionTitle: localization.string("panel.section.quarters", defaultValue: "四分")
        ))
        controls.append(contentsOf: actionRows(
            [
                .maximize, .almostMaximize, .grow, .shrink, .center,
            ],
            sectionTitle: localization.string("panel.section.scale", defaultValue: "缩放与位置")
        ))
        controls.append(contentsOf: actionRows(
            [.restore],
            sectionTitle: localization.string("panel.section.restore", defaultValue: "恢复"),
            restoreEnabled: !history.isEmpty
        ))
        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func actionRows(
        _ actions: [WindowLayoutAction],
        sectionTitle: String,
        restoreEnabled: Bool = true
    ) -> [PluginPanelControl] {
        actions.enumerated().map { index, action in
            PluginPanelControl(
                id: action.rawValue,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: index == 0 ? sectionTitle : nil,
                actionTitle: title(for: action),
                actionIconSystemName: systemImage(for: action),
                actionBehavior: .keepPresented,
                isEnabled: action == .restore ? restoreEnabled && isAccessibilityGranted : isAccessibilityGranted
            )
        }
    }

    private func title(for action: WindowLayoutAction) -> String {
        switch action {
        case .maximize:
            return localization.string("action.maximize", defaultValue: "最大化")
        case .almostMaximize:
            return localization.string("action.almostMaximize", defaultValue: "接近最大化")
        case .leftHalf:
            return localization.string("action.leftHalf", defaultValue: "左半屏")
        case .rightHalf:
            return localization.string("action.rightHalf", defaultValue: "右半屏")
        case .topHalf:
            return localization.string("action.topHalf", defaultValue: "上半屏")
        case .bottomHalf:
            return localization.string("action.bottomHalf", defaultValue: "下半屏")
        case .centerHalf:
            return localization.string("action.centerHalf", defaultValue: "中间半屏")
        case .leftThird:
            return localization.string("action.leftThird", defaultValue: "左三分之一")
        case .centerThird:
            return localization.string("action.centerThird", defaultValue: "中三分之一")
        case .rightThird:
            return localization.string("action.rightThird", defaultValue: "右三分之一")
        case .leftTwoThirds:
            return localization.string("action.leftTwoThirds", defaultValue: "左三分之二")
        case .rightTwoThirds:
            return localization.string("action.rightTwoThirds", defaultValue: "右三分之二")
        case .topLeftQuarter:
            return localization.string("action.topLeftQuarter", defaultValue: "左上 1/4")
        case .topRightQuarter:
            return localization.string("action.topRightQuarter", defaultValue: "右上 1/4")
        case .bottomLeftQuarter:
            return localization.string("action.bottomLeftQuarter", defaultValue: "左下 1/4")
        case .bottomRightQuarter:
            return localization.string("action.bottomRightQuarter", defaultValue: "右下 1/4")
        case .grow:
            return localization.string("action.grow", defaultValue: "放大")
        case .shrink:
            return localization.string("action.shrink", defaultValue: "缩小")
        case .center:
            return localization.string("action.center", defaultValue: "居中")
        case .restore:
            return localization.string("action.restore", defaultValue: "恢复")
        }
    }

    private func systemImage(for action: WindowLayoutAction) -> String {
        switch action {
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: return "rectangle.inset.filled"
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .centerHalf: return "rectangle.center.inset.filled"
        case .leftThird, .leftTwoThirds: return "rectangle.split.3x1"
        case .centerThird: return "rectangle.split.3x1"
        case .rightThird, .rightTwoThirds: return "rectangle.split.3x1"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            return "rectangle.split.2x2"
        case .grow: return "plus.magnifyingglass"
        case .shrink: return "minus.magnifyingglass"
        case .center: return "arrow.up.and.down.and.arrow.left.and.right"
        case .restore: return "arrow.uturn.backward"
        }
    }

    private func userMessage(for error: Error) -> String {
        let applyError = (error as? WindowLayoutApplyError) ?? .axFailure
        switch applyError {
        case .accessibilityDenied:
            return localization.string("error.accessibilityRequired", defaultValue: "需要辅助功能权限")
        case .noResizableWindow:
            return localization.string("error.noResizableWindow", defaultValue: "没有可调整的前台窗口")
        case .axFailure:
            return localization.string("error.axFailure", defaultValue: "无法调整该窗口")
        case .nothingToRestore:
            return localization.string("error.nothingToRestore", defaultValue: "没有可恢复的窗口位置")
        }
    }
}
