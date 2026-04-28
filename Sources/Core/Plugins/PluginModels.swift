import Foundation
import SwiftUI

struct PluginMetadata: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let iconTint: Color
    let order: Int
    let defaultDescription: String
}

enum PluginControlStyle {
    case `switch`
    case disclosure
}

enum PluginPanelAction: Equatable {
    enum SliderPhase: Equatable {
        case changed
        case ended
    }

    case setSwitch(Bool)
    case setDisclosureExpanded(Bool)
    case setSelection(controlID: String, optionID: String)
    case setNavigationSelection(controlID: String, optionID: String)
    case clearNavigationSelection(controlID: String)
    case setDate(controlID: String, value: Date)
    case setSlider(controlID: String, value: Double, phase: SliderPhase)
    case invokeAction(controlID: String)
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

    var metadata: PluginMetadata {
        PluginMetadata(
            id: id,
            title: title,
            iconName: iconName,
            iconTint: iconTint,
            order: order,
            defaultDescription: defaultDescription
        )
    }
}

struct PluginComponentSpan: Equatable, Hashable {
    static let maximumWidth = 4

    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard Self.isValid(width: width, height: height) else {
            return nil
        }

        self.width = width
        self.height = height
    }

    private init(uncheckedWidth width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    static let oneByOne = PluginComponentSpan(uncheckedWidth: 1, height: 1)
    static let oneByTwo = PluginComponentSpan(uncheckedWidth: 1, height: 2)
    static let twoByOne = PluginComponentSpan(uncheckedWidth: 2, height: 1)
    static let twoByTwo = PluginComponentSpan(uncheckedWidth: 2, height: 2)
    static let fourByTwo = PluginComponentSpan(uncheckedWidth: 4, height: 2)

    static func isValid(width: Int, height: Int) -> Bool {
        (1...maximumWidth).contains(width) && height >= 1
    }
}

struct PluginComponentDescriptor {
    let span: PluginComponentSpan

    init(span: PluginComponentSpan) {
        self.span = span
    }
}

struct PluginComponentState {
    let subtitle: String
    let isActive: Bool
    let isEnabled: Bool
    let isVisible: Bool
    let errorMessage: String?
}

struct PluginComponentContext {
    let pluginID: String
    let dismiss: () -> Void
}

struct PluginComponentItem: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let iconTint: Color
    let description: String
    let helpText: String
    let descriptionTone: PluginPanelDescriptionTone
    let span: PluginComponentSpan
    let isActive: Bool
    let isEnabled: Bool
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
    case navigationList
    case slider
    case actionRow
}

enum PluginPanelDatePickerStyle {
    case compact
    case dateTimeCard
}

struct PluginPanelControlOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?

    init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
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
    let sliderValue: Double?
    let sliderBounds: ClosedRange<Double>?
    let sliderStep: Double?
    let valueLabel: String?
    let actionTitle: String?
    let actionIconSystemName: String?
    let actionBehavior: PluginMenuActionBehavior
    let showsLeadingDivider: Bool
    let isEnabled: Bool

    init(
        id: String,
        kind: PluginPanelControlKind,
        options: [PluginPanelControlOption],
        selectedOptionID: String?,
        dateValue: Date?,
        minimumDate: Date?,
        displayedComponents: DatePickerComponents?,
        datePickerStyle: PluginPanelDatePickerStyle?,
        sectionTitle: String?,
        sliderValue: Double? = nil,
        sliderBounds: ClosedRange<Double>? = nil,
        sliderStep: Double? = nil,
        valueLabel: String? = nil,
        actionTitle: String? = nil,
        actionIconSystemName: String? = nil,
        actionBehavior: PluginMenuActionBehavior = .keepPresented,
        showsLeadingDivider: Bool = false,
        isEnabled: Bool
    ) {
        self.id = id
        self.kind = kind
        self.options = options
        self.selectedOptionID = selectedOptionID
        self.dateValue = dateValue
        self.minimumDate = minimumDate
        self.displayedComponents = displayedComponents
        self.datePickerStyle = datePickerStyle
        self.sectionTitle = sectionTitle
        self.sliderValue = sliderValue
        self.sliderBounds = sliderBounds
        self.sliderStep = sliderStep
        self.valueLabel = valueLabel
        self.actionTitle = actionTitle
        self.actionIconSystemName = actionIconSystemName
        self.actionBehavior = actionBehavior
        self.showsLeadingDivider = showsLeadingDivider
        self.isEnabled = isEnabled
    }
}

struct PluginPanelSecondaryPanel {
    let title: String
    let controls: [PluginPanelControl]
}

struct PluginPanelDetail {
    let primaryControls: [PluginPanelControl]
    let secondaryPanel: PluginPanelSecondaryPanel?

    var controls: [PluginPanelControl] {
        primaryControls
    }

    init(primaryControls: [PluginPanelControl], secondaryPanel: PluginPanelSecondaryPanel?) {
        self.primaryControls = primaryControls
        self.secondaryPanel = secondaryPanel
    }

    init(controls: [PluginPanelControl]) {
        self.init(primaryControls: controls, secondaryPanel: nil)
    }
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

enum PluginFeaturePresentation: Equatable {
    case featurePanel
    case componentPanel
    case featureAndComponentPanel
}

struct PluginFeatureManagementItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let isVisible: Bool
    let isActive: Bool
    let presentation: PluginFeaturePresentation
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
