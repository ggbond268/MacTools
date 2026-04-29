import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private enum ControlID {
    static let displayNavigation = "display-navigation"
    static let openSystemSettings = "display-open-system-settings"
}

@MainActor
protocol DisplaySystemSettingsLauncher {
    @discardableResult
    func openDisplaySettings() -> Bool
}

@MainActor
struct WorkspaceDisplaySystemSettingsLauncher: DisplaySystemSettingsLauncher {
    // 直接打开「系统设置 → 显示器」，对 Ventura+ 的 System Settings 与
    // 旧版 System Preferences 都有效。
    private static let systemDisplaySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays")!

    @discardableResult
    func openDisplaySettings() -> Bool {
        NSWorkspace.shared.open(Self.systemDisplaySettingsURL)
    }
}

@MainActor
final class DisplayResolutionPlugin: FeaturePlugin {
    private static let unavailableModesSubtitle = "未检测到可用分辨率"
    private static let openSystemSettingsTitle = "打开系统显示器设置"
    private static let openSystemSettingsIcon = "gearshape"

    let manifest = PluginManifest(
        id: "display-resolution",
        title: "显示器分辨率",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented,
        order: 30,
        defaultDescription: "查看并切换每个显示器的分辨率"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private var isExpanded = false
    private var selectedDisplayID: CGDirectDisplayID?
    private var lastErrorMessage: String?
    private let controller: DisplayResolutionControlling
    private let systemSettingsLauncher: DisplaySystemSettingsLauncher

    init(
        controller: DisplayResolutionControlling = DisplayResolutionController(),
        systemSettingsLauncher: DisplaySystemSettingsLauncher = WorkspaceDisplaySystemSettingsLauncher()
    ) {
        self.controller = controller
        self.systemSettingsLauncher = systemSettingsLauncher
    }

    var panelState: PluginPanelState {
        let displays = controller.listConnectedDisplays()
        let panelDisplays = displays.compactMap { display -> PanelDisplay? in
            let modes = Self.visibleModes(controller.listAvailableResolutions(for: display.id))
            guard !modes.isEmpty else {
                return nil
            }
            return PanelDisplay(display: display, modes: modes)
        }

        if !panelDisplays.contains(where: { $0.display.id == selectedDisplayID }) {
            selectedDisplayID = nil
        }

        guard !displays.isEmpty else {
            selectedDisplayID = nil
            return PluginPanelState(
                subtitle: "未检测到可用显示器",
                isOn: false,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: nil
            )
        }

        guard !panelDisplays.isEmpty else {
            selectedDisplayID = nil
            return PluginPanelState(
                subtitle: Self.unavailableModesSubtitle,
                isOn: false,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: nil
            )
        }

        return PluginPanelState(
            subtitle: subtitleForRowState(panelDisplays),
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail(for: panelDisplays) : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}

    func handlePanelAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            if !value {
                selectedDisplayID = nil
            }
            lastErrorMessage = nil
            onStateChange?()
        case let .setNavigationSelection(controlID, optionID):
            guard
                controlID == ControlID.displayNavigation,
                let rawDisplayID = UInt32(optionID)
            else {
                return
            }

            let displayID = CGDirectDisplayID(rawDisplayID)
            selectedDisplayID = displayID
            lastErrorMessage = nil
            onStateChange?()
        case let .clearNavigationSelection(controlID):
            guard controlID == ControlID.displayNavigation else {
                return
            }

            selectedDisplayID = nil
            lastErrorMessage = nil
            onStateChange?()
        case let .setSelection(controlID, optionID):
            guard let displayID = Self.parseDisplayID(from: controlID), let modeId = Int32(optionID) else {
                AppLog.displayResolutionPlugin.error("invalid selection payload controlID=\(controlID, privacy: .public) optionID=\(optionID, privacy: .public)")
                return
            }

            guard controller.listConnectedDisplays().contains(where: { $0.id == displayID }) else {
                handleApplyFailure(.displayUnavailable(displayID: displayID), displayID: displayID, modeId: modeId)
                return
            }

            guard let target = controller.listAvailableResolutions(for: displayID).first(where: { $0.modeId == modeId }) else {
                handleApplyFailure(.modeNotFound(modeId: modeId), displayID: displayID, modeId: modeId)
                return
            }

            AppLog.displayResolutionPlugin.info("applying \(target.width)×\(target.height) on display \(displayID)")

            switch controller.applyResolution(target, for: displayID) {
            case .success:
                lastErrorMessage = nil
                AppLog.displayResolutionPlugin.info("applied \(target.width)×\(target.height) on display \(displayID)")
                onStateChange?()
            case .failure(let error):
                handleApplyFailure(error, displayID: displayID, modeId: modeId)
            }
        case let .invokeAction(controlID):
            guard controlID == ControlID.openSystemSettings else {
                return
            }

            let opened = systemSettingsLauncher.openDisplaySettings()
            if !opened {
                AppLog.displayResolutionPlugin.error("failed to open system display settings via NSWorkspace")
            }
        case .setSwitch, .setDate, .setSlider:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    nonisolated static func visibleModes(_ modes: [DisplayResolutionInfo]) -> [DisplayResolutionInfo] {
        guard let first = modes.first else { return [] }
        let nativeAspect = modes.first(where: { $0.isNative })?.aspectRatio ?? first.aspectRatio
        return modes.filter { mode in
            abs(mode.aspectRatio - nativeAspect) < 0.005 || mode.isCurrent
        }
    }

    nonisolated static func optionTitle(for mode: DisplayResolutionInfo) -> String {
        var title = "\(mode.width)×\(mode.height)"
        if mode.isNative {
            title += " (原生)"
        } else if mode.isDefault {
            title += " (默认)"
        } else if mode.isHiDPI {
            title += " (HiDPI)"
        } else {
            title += " (LoDPI)"
        }
        return title
    }

    nonisolated static func parseDisplayID(from controlID: String) -> CGDirectDisplayID? {
        let prefix = "display."
        guard controlID.hasPrefix(prefix) else { return nil }
        return CGDirectDisplayID(controlID.dropFirst(prefix.count))
    }

    private func subtitleForRowState(_ displays: [PanelDisplay]) -> String {
        if displays.count == 1, let display = displays.first {
            let current = display.modes.first(where: { $0.isCurrent })
            return current.map {
                "\(display.display.isMain ? "主屏" : display.display.name) \($0.displayTitle)"
            } ?? manifest.defaultDescription
        }
        return "\(displays.count) 个显示器"
    }

    private func buildDetail(for displays: [PanelDisplay]) -> PluginPanelDetail {
        let displayNavigation = PluginPanelControl(
            id: ControlID.displayNavigation,
            kind: .navigationList,
            options: displays.map { display in
                let currentSummary = display.modes.first(where: { $0.isCurrent })?.displayTitle ?? "未知"

                return PluginPanelControlOption(
                    id: String(display.display.id),
                    title: display.display.name,
                    subtitle: currentSummary
                )
            },
            selectedOptionID: selectedDisplayID.map(String.init),
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        )

        let openSystemSettings = PluginPanelControl(
            id: ControlID.openSystemSettings,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: Self.openSystemSettingsTitle,
            actionIconSystemName: Self.openSystemSettingsIcon,
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        )

        let navigationSecondaryPanels = displays.map { display in
            PluginPanelNavigationSecondaryPanel(
                controlID: ControlID.displayNavigation,
                optionID: String(display.display.id),
                panel: Self.secondaryPanel(for: display)
            )
        }
        let secondaryPanel = selectedDisplayID.flatMap { selectedID in
            displays.first(where: { $0.display.id == selectedID }).map(Self.secondaryPanel(for:))
        }

        return PluginPanelDetail(
            primaryControls: [displayNavigation, openSystemSettings],
            secondaryPanel: secondaryPanel,
            navigationSecondaryPanels: navigationSecondaryPanels
        )
    }

    private static func secondaryPanel(for display: PanelDisplay) -> PluginPanelSecondaryPanel {
        let resolutionControl = PluginPanelControl(
            id: "display.\(display.display.id)",
            kind: .selectList,
            options: display.modes.map {
                PluginPanelControlOption(
                    id: String($0.modeId),
                    title: Self.optionTitle(for: $0),
                    subtitle: nil
                )
            },
            selectedOptionID: display.modes.first(where: { $0.isCurrent }).map { String($0.modeId) },
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        )

        return PluginPanelSecondaryPanel(title: display.display.name, controls: [resolutionControl])
    }

    private func handleApplyFailure(
        _ error: DisplayResolutionError,
        displayID: CGDirectDisplayID,
        modeId: Int32
    ) {
        AppLog.displayResolutionPlugin.error(
            "apply failed display=\(displayID) modeId=\(modeId) reason=\(error.localizedDescription, privacy: .public)"
        )
        lastErrorMessage = "切换失败：\(error.localizedDescription)"
        onStateChange?()
    }
}

private struct PanelDisplay {
    let display: DisplayInfo
    let modes: [DisplayResolutionInfo]
}
