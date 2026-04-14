import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class DisplayResolutionPlugin: FeaturePlugin {
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
    private var lastErrorMessage: String?
    private let controller = DisplayResolutionController()

    var panelState: PluginPanelState {
        let displays = controller.listConnectedDisplays()

        guard !displays.isEmpty else {
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

        return PluginPanelState(
            subtitle: subtitleForRowState(displays),
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail(for: displays) : nil,
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
        case .setSwitch, .setDate:
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
        }
        return title
    }

    nonisolated static func parseDisplayID(from controlID: String) -> CGDirectDisplayID? {
        let prefix = "display."
        guard controlID.hasPrefix(prefix) else { return nil }
        return CGDirectDisplayID(controlID.dropFirst(prefix.count))
    }

    private func subtitleForRowState(_ displays: [DisplayInfo]) -> String {
        if displays.count == 1, let display = displays.first {
            let current = controller.listAvailableResolutions(for: display.id).first(where: { $0.isCurrent })
            return current.map { "\(display.isMain ? "主屏" : display.name) \($0.displayTitle)" } ?? manifest.defaultDescription
        }
        return "\(displays.count) 个显示器"
    }

    private func buildDetail(for displays: [DisplayInfo]) -> PluginPanelDetail {
        let controls = displays.compactMap { display -> PluginPanelControl? in
            let modes = Self.visibleModes(controller.listAvailableResolutions(for: display.id))
            guard !modes.isEmpty else { return nil }

            return PluginPanelControl(
                id: "display.\(display.id)",
                kind: .selectList,
                options: modes.map { PluginPanelControlOption(id: String($0.modeId), title: Self.optionTitle(for: $0)) },
                selectedOptionID: modes.first(where: { $0.isCurrent }).map { String($0.modeId) },
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: display.name,
                isEnabled: true
            )
        }

        return PluginPanelDetail(controls: controls)
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
