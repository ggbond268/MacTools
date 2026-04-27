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
        static let scan = "disk-clean-scan"
        static let clean = "disk-clean-clean"
        static let openDetails = "disk-clean-open-details"
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
        switch controlID {
        case ControlID.scan:
            controller.scan()
        case ControlID.clean:
            controller.cleanSelected(candidateIDs: cleanableCandidateIDs)
        case ControlID.openDetails:
            break
        default:
            break
        }
    }

    private func buildDetail(for snapshot: DiskCleanControllerSnapshot) -> PluginPanelDetail {
        let scanControl = PluginPanelControl(
            id: ControlID.scan,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "扫描",
            actionIconSystemName: "magnifyingglass",
            isEnabled: snapshot.canScan
        )

        let cleanControl = PluginPanelControl(
            id: ControlID.clean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "清理",
            actionIconSystemName: "trash",
            showsLeadingDivider: true,
            isEnabled: snapshot.canClean
        )

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
            primaryControls: [scanControl, cleanControl, openDetailsControl],
            secondaryPanel: nil
        )
    }

    private func subtitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        if snapshot.phase == .scanned,
           !snapshot.isResultStale,
           let result = snapshot.scanResult {
            return "\(result.cleanableCandidates.count) 项，\(byteText(result.cleanableSizeBytes))"
        }

        if snapshot.phase == .completed,
           let result = snapshot.executionResult {
            return "已清理 \(byteText(result.reclaimedBytes))"
        }

        return snapshot.subtitle
    }

    private var cleanableCandidateIDs: Set<DiskCleanCandidate.ID> {
        Set(controller.snapshot.scanResult?.cleanableCandidates.map(\.id) ?? [])
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
