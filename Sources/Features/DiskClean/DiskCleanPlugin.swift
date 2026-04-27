import Foundation
import SwiftUI

@MainActor
final class DiskCleanFeature {
    static let shared = DiskCleanFeature()

    let controller: DiskCleanController

    private init(controller: DiskCleanController = DiskCleanController()) {
        self.controller = controller
    }

    func makePlugin() -> DiskCleanPlugin {
        DiskCleanPlugin(controller: controller)
    }
}

@MainActor
final class DiskCleanPlugin: FeaturePlugin {
    enum ControlID {
        static let choicePrefix = "disk-clean-choice."
        static let testMode = "disk-clean-test-mode"
        static let scan = "disk-clean-scan"
        static let cancel = "disk-clean-cancel"
        static let openDetails = "disk-clean-open-details"

        static func choice(_ choice: DiskCleanChoice) -> String {
            "\(choicePrefix)\(choice.rawValue)"
        }
    }

    let manifest = PluginManifest(
        id: "disk-clean",
        title: "磁盘清理",
        iconName: "internaldrive",
        iconTint: Color(nsColor: .systemGreen),
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented,
        order: 90,
        defaultDescription: "缓存、开发者缓存和浏览器缓存清理"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let controller: DiskCleanControlling
    private var isExpanded = false

    init(controller: DiskCleanControlling = DiskCleanFeature.shared.controller) {
        self.controller = controller
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var panelState: PluginPanelState {
        let snapshot = controller.snapshot

        return PluginPanelState(
            subtitle: subtitle(for: snapshot),
            isOn: snapshot.isBusy,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail(for: snapshot) : nil,
            errorMessage: snapshot.errorMessage
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
            onStateChange?()
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private func handleInvoke(controlID: String) {
        if let choice = choice(from: controlID) {
            let isSelected = controller.snapshot.selectedChoices.contains(choice)
            controller.setChoice(choice, isSelected: !isSelected)
            return
        }

        switch controlID {
        case ControlID.testMode:
            controller.setTestModeEnabled(!controller.snapshot.isTestModeEnabled)
        case ControlID.scan:
            controller.scan()
        case ControlID.cancel:
            controller.cancelCurrentOperation()
        case ControlID.openDetails:
            break
        default:
            break
        }
    }

    private func choice(from controlID: String) -> DiskCleanChoice? {
        guard controlID.hasPrefix(ControlID.choicePrefix) else {
            return nil
        }

        let rawValue = String(controlID.dropFirst(ControlID.choicePrefix.count))
        return DiskCleanChoice(rawValue: rawValue)
    }

    private func buildDetail(for snapshot: DiskCleanControllerSnapshot) -> PluginPanelDetail {
        let choiceControls = DiskCleanChoice.allCases.map { choice in
            choiceControl(for: choice, snapshot: snapshot)
        }

        let testModeControl = PluginPanelControl(
            id: ControlID.testMode,
            kind: .actionRow,
            options: [],
            selectedOptionID: snapshot.isTestModeEnabled ? "enabled" : nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "测试模式：只列出文件",
            actionIconSystemName: snapshot.isTestModeEnabled ? "checkmark.circle.fill" : "circle",
            showsLeadingDivider: true,
            isEnabled: !snapshot.isBusy
        )

        let operationControl: PluginPanelControl
        if snapshot.isBusy {
            operationControl = PluginPanelControl(
                id: ControlID.cancel,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: "停止",
                actionIconSystemName: "xmark.circle",
                showsLeadingDivider: true,
                isEnabled: true
            )
        } else {
            operationControl = PluginPanelControl(
                id: ControlID.scan,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: "扫描可清理项目",
                actionIconSystemName: "magnifyingglass",
                showsLeadingDivider: true,
                isEnabled: snapshot.canScan
            )
        }

        let openDetailsControl = PluginPanelControl(
            id: ControlID.openDetails,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "打开详情",
            actionIconSystemName: "arrow.up.right.square",
            actionBehavior: .dismissBeforeHandling,
            isEnabled: true
        )

        return PluginPanelDetail(
            primaryControls: choiceControls + [testModeControl, operationControl, openDetailsControl],
            secondaryPanel: nil
        )
    }

    private func choiceControl(
        for choice: DiskCleanChoice,
        snapshot: DiskCleanControllerSnapshot
    ) -> PluginPanelControl {
        let isSelected = snapshot.selectedChoices.contains(choice)

        return PluginPanelControl(
            id: ControlID.choice(choice),
            kind: .actionRow,
            options: [],
            selectedOptionID: isSelected ? choice.rawValue : nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: choice.title,
            actionIconSystemName: isSelected ? "checkmark.circle.fill" : "circle",
            isEnabled: !snapshot.isBusy
        )
    }

    private func subtitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        if snapshot.phase == .scanned,
           !snapshot.isResultStale,
           let result = snapshot.scanResult {
            let prefix = snapshot.isTestModeEnabled ? "测试模式 " : ""
            return "\(prefix)\(result.cleanableCandidates.count) 项，\(byteText(result.cleanableSizeBytes))"
        }

        if snapshot.phase == .completed,
           let result = snapshot.executionResult {
            return "已清理 \(byteText(result.reclaimedBytes))"
        }

        return snapshot.subtitle
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
