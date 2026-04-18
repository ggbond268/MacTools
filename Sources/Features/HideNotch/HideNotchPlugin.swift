import Foundation
import SwiftUI

@MainActor
final class HideNotchPlugin: FeaturePlugin {
    let manifest = PluginManifest(
        id: "hide-notch",
        title: "隐藏刘海",
        iconName: "macbook.and.iphone",
        iconTint: Color(nsColor: .labelColor),
        controlStyle: .switch,
        menuActionBehavior: .keepPresented,
        order: 40,
        defaultDescription: "自动遮挡刘海屏顶部区域"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let controller: HideNotchWallpaperControlling

    init(controller: HideNotchWallpaperControlling = HideNotchController()) {
        self.controller = controller
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var panelState: PluginPanelState {
        let snapshot = controller.snapshot()

        if !snapshot.hasSupportedDisplay {
            let subtitle = snapshot.isEnabled ? "已开启" : "未检测到刘海屏"

            return PluginPanelState(
                subtitle: subtitle,
                isOn: snapshot.isEnabled,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: snapshot.errorMessage
            )
        }

        let subtitle: String
        if snapshot.isEnabled {
            subtitle = "已开启"
        } else if snapshot.isProcessing {
            subtitle = "正在关闭"
        } else {
            subtitle = manifest.defaultDescription
        }

        return PluginPanelState(
            subtitle: subtitle,
            isOn: snapshot.isEnabled,
            isExpanded: false,
            isEnabled: !snapshot.isProcessing,
            isVisible: true,
            detail: nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        controller.refresh()
    }

    func handlePanelAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        controller.setEnabled(isEnabled)
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}
