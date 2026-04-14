import Foundation
import SwiftUI

enum PluginControlStyle {
    case `switch`
    case disclosure
}

enum PluginPanelAction {
    case setSwitch(Bool)
    case setDisclosureExpanded(Bool)
    case setSelection(controlID: String, optionID: String)
    case setDate(controlID: String, value: Date)
}

enum PluginPanelDescriptionTone {
    case secondary
    case error
}

enum PluginMenuActionBehavior {
    case keepPresented
    case dismissBeforeHandling
}

enum PluginStatusTone {
    case neutral
    case positive
    case caution
}

enum PluginPermissionKind {
    case accessibility
}

enum SettingsDestination: Hashable {
    case general
    case shortcuts
    case about
}

struct PluginManifest: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let iconTint: Color
    let controlStyle: PluginControlStyle
    let menuActionBehavior: PluginMenuActionBehavior
    let order: Int
    let defaultDescription: String
}

struct PluginPanelState {
    let subtitle: String
    let isOn: Bool
    let isExpanded: Bool
    let isEnabled: Bool
    let isVisible: Bool
    let detail: PluginPanelDetail?
    let errorMessage: String?
}

enum PluginPanelControlKind {
    case segmented
    case datePicker
    case selectList
}

enum PluginPanelDatePickerStyle {
    case compact
    case dateTimeCard
}

struct PluginPanelControlOption: Identifiable {
    let id: String
    let title: String
}

struct PluginPanelControl: Identifiable {
    let id: String
    let kind: PluginPanelControlKind
    let options: [PluginPanelControlOption]
    let selectedOptionID: String?
    let dateValue: Date?
    let minimumDate: Date?
    let displayedComponents: DatePickerComponents?
    let datePickerStyle: PluginPanelDatePickerStyle?
    let sectionTitle: String?
    let isEnabled: Bool
}

struct PluginPanelDetail {
    let controls: [PluginPanelControl]
}

struct PluginPermissionRequirement: Identifiable {
    let id: String
    let kind: PluginPermissionKind
    let title: String
    let description: String
}

struct PluginPermissionState {
    let isGranted: Bool
    let footnote: String?
}

struct PluginSettingsSection: Identifiable {
    struct Status {
        let text: String
        let systemImage: String
        let tone: PluginStatusTone
    }

    let id: String
    let title: String
    let description: String
    let status: Status
    let footnote: String?
    let buttonTitle: String?
    let actionID: String?
}

struct PluginPanelItem: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let iconTint: Color
    let controlStyle: PluginControlStyle
    let menuActionBehavior: PluginMenuActionBehavior
    let description: String
    let helpText: String
    let descriptionTone: PluginPanelDescriptionTone
    let isOn: Bool
    let isExpanded: Bool
    let isEnabled: Bool
    let detail: PluginPanelDetail?
}

struct PluginFeatureManagementItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let isVisible: Bool
    let isActive: Bool
}

struct PluginPermissionCard: Identifiable {
    let id: String
    let pluginID: String
    let permissionID: String
    let title: String
    let description: String
    let statusText: String
    let statusSystemImage: String
    let statusTone: PluginStatusTone
    let footnote: String?
    let buttonTitle: String
}

struct PluginSettingsCard: Identifiable {
    let id: String
    let pluginID: String
    let title: String
    let description: String
    let statusText: String
    let statusSystemImage: String
    let statusTone: PluginStatusTone
    let footnote: String?
    let buttonTitle: String?
    let actionID: String?
}
