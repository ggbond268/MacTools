import Foundation
import SwiftUI

public struct PluginMetadata: Identifiable {
    public let id: String
    public let title: String
    public let iconName: String
    public let iconTint: Color
    public let order: Int
    public let defaultDescription: String

    public init(
        id: String,
        title: String,
        iconName: String,
        iconTint: Color,
        order: Int,
        defaultDescription: String
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.iconTint = iconTint
        self.order = order
        self.defaultDescription = defaultDescription
    }
}

public enum PluginControlStyle {
    case `switch`
    case disclosure
    case button
}

public enum PluginPanelAction: Equatable {
    public enum SliderPhase: Equatable {
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

public enum PluginPanelDescriptionTone {
    case secondary
    case error
}

public enum PluginMenuActionBehavior {
    case keepPresented
    case dismissBeforeHandling
}

public enum PluginStatusTone: Equatable, Sendable {
    case neutral
    case positive
    case caution
}

public enum PluginPermissionKind {
    case accessibility
    case inputMonitoring
    case calendarFullAccess
    case automation
    case screenRecording
    case finderExtension
}

public enum SettingsDestination: Hashable {
    case general
    case pluginConfiguration
    case about
}

public enum PluginDeactivationReason: Equatable {
    case disabled
    case uninstalling
    case updating
    case hostShutdown

    /// `true` when the plugin should revert any external side-effects it owns
    /// (host isolation, plugin uninstalled, or app is quitting).
    /// `false` during hot-reload updates — the new version will re-activate.
    public var requiresStateCleanup: Bool {
        switch self {
        case .disabled, .uninstalling, .hostShutdown: true
        case .updating: false
        }
    }
}

public enum MenuBarControlItemDefaults {
    public static let visibleAutosaveName = "MacTools.ControlItem.Visible"
    public static let hiddenAutosaveName = "MacTools.ControlItem.Hidden"
    public static let alwaysHiddenAutosaveName = "MacTools.ControlItem.AlwaysHidden"
    public static let visibleDefaultPreferredPosition: Double = 0
    public static let hiddenDefaultPreferredPosition: Double = 1
    public static let adjacentPreferredPositionOffset: Double = 0.5
    private static let visiblePreferredPositionBackupKey = "MacTools.ControlItem.Visible.PreferredPositionBackup"

    public static func prepareVisibleControlItem(userDefaults: UserDefaults = .standard) {
        restoreVisibleControlItemPreferredPositionIfMissing(userDefaults: userDefaults)
        prepareControlItemVisibility(autosaveName: visibleAutosaveName, userDefaults: userDefaults)
    }

    public static func resetVisibleControlItemPosition(userDefaults: UserDefaults = .standard) {
        prepareControlItem(
            autosaveName: visibleAutosaveName,
            preferredPosition: preferredPositionForVisibleControlItemRightOfHiddenDivider(userDefaults: userDefaults),
            alwaysResetPreferredPosition: true,
            userDefaults: userDefaults
        )
    }

    public static func visibleControlItemPreferredPosition(userDefaults: UserDefaults = .standard) -> Double? {
        userDefaults.object(forKey: preferredPositionKey(visibleAutosaveName)) as? Double
    }

    public static func setVisibleControlItemPreferredPosition(
        _ position: Double?,
        userDefaults: UserDefaults = .standard
    ) {
        setPreferredPosition(position, autosaveName: visibleAutosaveName, userDefaults: userDefaults)
    }

    public static func snapshotVisibleControlItemPreferredPosition(userDefaults: UserDefaults = .standard) {
        guard let preferredPosition = visibleControlItemPreferredPosition(userDefaults: userDefaults) else {
            return
        }

        userDefaults.set(preferredPosition, forKey: visiblePreferredPositionBackupKey)
    }

    public static func restoreVisibleControlItemPreferredPositionIfMissing(
        userDefaults: UserDefaults = .standard
    ) {
        guard
            visibleControlItemPreferredPosition(userDefaults: userDefaults) == nil,
            let preferredPosition = userDefaults.object(forKey: visiblePreferredPositionBackupKey) as? Double
        else {
            return
        }

        setVisibleControlItemPreferredPosition(preferredPosition, userDefaults: userDefaults)
    }

    public static func visibleControlItemNeedsRecovery(userDefaults: UserDefaults = .standard) -> Bool {
        guard
            let visiblePosition = visibleControlItemPreferredPosition(userDefaults: userDefaults),
            let hiddenDividerPosition = hiddenDividerControlItemPreferredPosition(userDefaults: userDefaults)
        else {
            return false
        }

        return visiblePosition >= hiddenDividerPosition
    }

    public static func prepareHiddenDividerControlItem(
        preferredPosition: Double = hiddenDefaultPreferredPosition,
        userDefaults: UserDefaults = .standard
    ) {
        prepareControlItem(
            autosaveName: hiddenAutosaveName,
            preferredPosition: preferredPosition,
            alwaysResetPreferredPosition: false,
            userDefaults: userDefaults
        )
    }

    public static func hiddenDividerControlItemPreferredPosition(userDefaults: UserDefaults = .standard) -> Double? {
        userDefaults.object(forKey: preferredPositionKey(hiddenAutosaveName)) as? Double
    }

    public static func setHiddenDividerControlItemPreferredPosition(
        _ position: Double?,
        userDefaults: UserDefaults = .standard
    ) {
        setPreferredPosition(position, autosaveName: hiddenAutosaveName, userDefaults: userDefaults)
    }

    public static func prepareAlwaysHiddenDividerControlItem(userDefaults: UserDefaults = .standard) {
        setPreferredPosition(nil, autosaveName: alwaysHiddenAutosaveName, userDefaults: userDefaults)
        prepareControlItemVisibility(
            autosaveName: alwaysHiddenAutosaveName,
            userDefaults: userDefaults
        )
    }

    public static func alwaysHiddenDividerControlItemPreferredPosition(userDefaults: UserDefaults = .standard) -> Double? {
        userDefaults.object(forKey: preferredPositionKey(alwaysHiddenAutosaveName)) as? Double
    }

    public static func setAlwaysHiddenDividerControlItemPreferredPosition(
        _ position: Double?,
        userDefaults: UserDefaults = .standard
    ) {
        setPreferredPosition(position, autosaveName: alwaysHiddenAutosaveName, userDefaults: userDefaults)
    }

    public static func preferredPositionForVisibleControlItemRightOfHiddenDivider(
        userDefaults: UserDefaults = .standard
    ) -> Double {
        let dividerPosition = hiddenDividerControlItemPreferredPosition(userDefaults: userDefaults)
            ?? hiddenDefaultPreferredPosition
        return dividerPosition - adjacentPreferredPositionOffset
    }

    public static func preferredPositionForHiddenDividerLeftOfVisibleControlItem(
        userDefaults: UserDefaults = .standard
    ) -> Double {
        let visiblePosition = visibleControlItemPreferredPosition(userDefaults: userDefaults)
            ?? visibleDefaultPreferredPosition
        return visiblePosition + adjacentPreferredPositionOffset
    }

    private static func prepareControlItem(
        autosaveName: String,
        preferredPosition: Double,
        alwaysResetPreferredPosition: Bool,
        userDefaults: UserDefaults
    ) {
        let preferredPositionKey = key("Preferred Position", autosaveName: autosaveName)
        if alwaysResetPreferredPosition || userDefaults.object(forKey: preferredPositionKey) == nil {
            userDefaults.set(preferredPosition, forKey: preferredPositionKey)
        }

        prepareControlItemVisibility(autosaveName: autosaveName, userDefaults: userDefaults)
    }

    private static func prepareControlItemVisibility(
        autosaveName: String,
        userDefaults: UserDefaults
    ) {
        let visibleKey = key("Visible", autosaveName: autosaveName)
        if userDefaults.object(forKey: visibleKey) == nil {
            userDefaults.set(true, forKey: visibleKey)
        }

        let visibleControlCenterKey = key("VisibleCC", autosaveName: autosaveName)
        if userDefaults.object(forKey: visibleControlCenterKey) == nil {
            userDefaults.set(true, forKey: visibleControlCenterKey)
        }
    }

    private static func key(_ rawValue: String, autosaveName: String) -> String {
        "NSStatusItem \(rawValue) \(autosaveName)"
    }

    private static func preferredPositionKey(_ autosaveName: String) -> String {
        key("Preferred Position", autosaveName: autosaveName)
    }

    private static func setPreferredPosition(
        _ position: Double?,
        autosaveName: String,
        userDefaults: UserDefaults
    ) {
        let key = preferredPositionKey(autosaveName)
        if let position {
            userDefaults.set(position, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
}

public struct PluginPrimaryPanelDescriptor {
    public let controlStyle: PluginControlStyle
    public let menuActionBehavior: PluginMenuActionBehavior
    private let staticButtonTitle: String?
    private let buttonTitleProvider: (() -> String?)?

    public var buttonTitle: String? {
        buttonTitleProvider?() ?? staticButtonTitle
    }

    public init(
        controlStyle: PluginControlStyle,
        menuActionBehavior: PluginMenuActionBehavior,
        buttonTitle: String? = nil
    ) {
        self.controlStyle = controlStyle
        self.menuActionBehavior = menuActionBehavior
        self.staticButtonTitle = buttonTitle
        self.buttonTitleProvider = nil
    }

    /// Keeps a button label current when a plugin supports runtime language
    /// switching without recreating the plugin or its active state.
    public init(
        controlStyle: PluginControlStyle,
        menuActionBehavior: PluginMenuActionBehavior,
        buttonTitleProvider: @escaping () -> String?
    ) {
        self.controlStyle = controlStyle
        self.menuActionBehavior = menuActionBehavior
        self.staticButtonTitle = nil
        self.buttonTitleProvider = buttonTitleProvider
    }
}

public struct PluginComponentSpan: Equatable, Hashable, Sendable {
    public static let maximumWidth = 4

    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
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

    public static let oneByOne = PluginComponentSpan(uncheckedWidth: 1, height: 1)
    public static let oneByTwo = PluginComponentSpan(uncheckedWidth: 1, height: 2)
    public static let twoByOne = PluginComponentSpan(uncheckedWidth: 2, height: 1)
    public static let twoByTwo = PluginComponentSpan(uncheckedWidth: 2, height: 2)
    public static let fourByTwo = PluginComponentSpan(uncheckedWidth: 4, height: 2)

    public static func isValid(width: Int, height: Int) -> Bool {
        (1...maximumWidth).contains(width) && height >= 1
    }
}

public struct PluginComponentPanelLayoutMetrics: Equatable, Sendable {
    public static let cardCornerRadius: CGFloat = 12

    public let columns: Int
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let horizontalSpacing: CGFloat
    public let verticalSpacing: CGFloat
    public let originalCellHeight: CGFloat

    public init(
        columns: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        originalCellHeight: CGFloat
    ) {
        self.columns = columns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.originalCellHeight = originalCellHeight
    }

    public static let `default`: PluginComponentPanelLayoutMetrics = {
        let originalCellHeight: CGFloat = 94
        let verticalSpacing: CGFloat = 8
        return PluginComponentPanelLayoutMetrics(
            columns: PluginComponentSpan.maximumWidth,
            cellWidth: 70,
            cellHeight: 8,
            horizontalSpacing: 8,
            verticalSpacing: verticalSpacing,
            originalCellHeight: originalCellHeight
        )
    }()

    public var gridWidth: CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * horizontalSpacing
    }

    public func itemWidth(forSpanWidth width: Int) -> CGFloat {
        CGFloat(width) * cellWidth + CGFloat(max(width - 1, 0)) * horizontalSpacing
    }

    public func itemHeight(forSpanHeight height: Int) -> CGFloat {
        CGFloat(height) * cellHeight
    }

    public func offsetX(forColumn column: Int) -> CGFloat {
        CGFloat(column) * (cellWidth + horizontalSpacing)
    }

    public func offsetY(forRow row: Int) -> CGFloat {
        CGFloat(row) * cellHeight
    }

    public func heightSpan(fittingContentHeight contentHeight: CGFloat) -> Int {
        guard contentHeight > 0 else {
            return 1
        }

        guard cellHeight > 0 else {
            return 1
        }

        return max(1, Int(ceil(contentHeight / cellHeight)))
    }

    public func heightSpan(closestToOriginalSpanHeight originalSpanHeight: Int) -> Int {
        guard originalSpanHeight > 0 else {
            return 1
        }

        let targetHeight = CGFloat(originalSpanHeight) * originalCellHeight
            + CGFloat(max(originalSpanHeight - 1, 0)) * verticalSpacing
        guard cellHeight > 0 else {
            return 1
        }

        return max(1, Int((targetHeight / cellHeight).rounded()))
    }
}

public struct PluginComponentDescriptor {
    public let span: PluginComponentSpan

    public init(span: PluginComponentSpan) {
        self.span = span
    }
}

public struct PluginComponentState {
    public let subtitle: String
    public let isActive: Bool
    public let isEnabled: Bool
    public let isVisible: Bool
    public let errorMessage: String?

    public init(
        subtitle: String,
        isActive: Bool,
        isEnabled: Bool,
        isVisible: Bool,
        errorMessage: String?
    ) {
        self.subtitle = subtitle
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.errorMessage = errorMessage
    }
}

public struct PluginComponentContext {
    public let pluginID: String
    public let dismiss: () -> Void
    public let isPanelVisible: Bool

    public init(pluginID: String, dismiss: @escaping () -> Void, isPanelVisible: Bool) {
        self.pluginID = pluginID
        self.dismiss = dismiss
        self.isPanelVisible = isPanelVisible
    }
}

public struct PluginComponentViewItem: Identifiable {
    public let id: String
    public let content: AnyView

    public init(id: String, content: AnyView) {
        self.id = id
        self.content = content
    }
}

public struct PluginComponentItem: Identifiable {
    public let id: String
    public let title: String
    public let iconName: String
    public let iconTint: Color
    public let description: String
    public let helpText: String
    public let descriptionTone: PluginPanelDescriptionTone
    public let span: PluginComponentSpan
    public let isActive: Bool
    public let isEnabled: Bool

    public init(
        id: String,
        title: String,
        iconName: String,
        iconTint: Color,
        description: String,
        helpText: String,
        descriptionTone: PluginPanelDescriptionTone,
        span: PluginComponentSpan,
        isActive: Bool,
        isEnabled: Bool
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.iconTint = iconTint
        self.description = description
        self.helpText = helpText
        self.descriptionTone = descriptionTone
        self.span = span
        self.isActive = isActive
        self.isEnabled = isEnabled
    }
}

public struct PluginPanelState {
    public let subtitle: String
    public let isOn: Bool
    public let isExpanded: Bool
    public let isEnabled: Bool
    public let isVisible: Bool
    public let detail: PluginPanelDetail?
    public let errorMessage: String?

    public init(
        subtitle: String,
        isOn: Bool,
        isExpanded: Bool,
        isEnabled: Bool,
        isVisible: Bool,
        detail: PluginPanelDetail?,
        errorMessage: String?
    ) {
        self.subtitle = subtitle
        self.isOn = isOn
        self.isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.detail = detail
        self.errorMessage = errorMessage
    }
}

public struct PluginPrimaryPanelIndicator: Equatable {
    public let text: String
    public let systemImage: String

    public init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

public struct PluginPrimaryPanelCompactIndicator: Equatable {
    public let icons: [PluginPrimaryPanelIndicatorIcon]

    public init(icons: [PluginPrimaryPanelIndicatorIcon]) {
        precondition(!icons.isEmpty, "Primary panel indicators require at least one icon.")
        self.icons = icons
    }
}

public struct PluginPrimaryPanelIndicatorIcon: Equatable {
    public let systemImage: String
    public let label: String
    public let accessibilityLabel: String

    public init(systemImage: String, label: String, accessibilityLabel: String) {
        self.systemImage = systemImage
        self.label = label
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum PluginPanelControlKind {
    case segmented
    case datePicker
    case selectList
    case navigationList
    case slider
    case actionRow
    case switchRow
}

public enum PluginPanelDatePickerStyle {
    case compact
    case dateTimeCard
}

public struct PluginPanelControlOption: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?

    public init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public struct PluginPanelControl: Identifiable {
    // Dynamic plugin bundles pass this value type across the PluginKit boundary.
    // Bump PluginKitCompatibility before changing stored property layout.
    public let id: String
    public let kind: PluginPanelControlKind
    public let options: [PluginPanelControlOption]
    public let selectedOptionID: String?
    public let dateValue: Date?
    public let minimumDate: Date?
    public let displayedComponents: DatePickerComponents?
    public let datePickerStyle: PluginPanelDatePickerStyle?
    public let sectionTitle: String?
    public let sliderValue: Double?
    public let sliderBounds: ClosedRange<Double>?
    public let sliderStep: Double?
    public let valueLabel: String?
    public let actionTitle: String?
    public let actionIconSystemName: String?
    public let actionBehavior: PluginMenuActionBehavior
    public let showsLeadingDivider: Bool
    public let isEnabled: Bool

    public init(
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

public struct PluginPanelSecondaryPanel {
    public let title: String
    public let controls: [PluginPanelControl]

    public init(title: String, controls: [PluginPanelControl]) {
        self.title = title
        self.controls = controls
    }
}

public struct PluginPanelNavigationSecondaryPanel {
    public let controlID: String
    public let optionID: String
    public let panel: PluginPanelSecondaryPanel

    public init(controlID: String, optionID: String, panel: PluginPanelSecondaryPanel) {
        self.controlID = controlID
        self.optionID = optionID
        self.panel = panel
    }
}

public struct PluginPanelDetail {
    public let primaryControls: [PluginPanelControl]
    public let secondaryPanel: PluginPanelSecondaryPanel?
    public let navigationSecondaryPanels: [PluginPanelNavigationSecondaryPanel]

    public var controls: [PluginPanelControl] {
        primaryControls
    }

    public init(
        primaryControls: [PluginPanelControl],
        secondaryPanel: PluginPanelSecondaryPanel?,
        navigationSecondaryPanels: [PluginPanelNavigationSecondaryPanel] = []
    ) {
        self.primaryControls = primaryControls
        self.secondaryPanel = secondaryPanel
        self.navigationSecondaryPanels = navigationSecondaryPanels
    }

    public init(controls: [PluginPanelControl]) {
        self.init(primaryControls: controls, secondaryPanel: nil)
    }

    public func secondaryPanel(controlID: String, optionID: String) -> PluginPanelSecondaryPanel? {
        if navigationSecondaryPanels.isEmpty {
            return secondaryPanel
        }

        return navigationSecondaryPanels.first {
            $0.controlID == controlID && $0.optionID == optionID
        }?.panel
    }
}

public struct PluginPermissionRequirement: Identifiable {
    public let id: String
    public let kind: PluginPermissionKind
    public let title: String
    public let description: String

    public init(id: String, kind: PluginPermissionKind, title: String, description: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.description = description
    }
}

public struct PluginPermissionState {
    public let isGranted: Bool
    public let footnote: String?
    public let statusText: String?
    public let statusSystemImage: String?
    public let statusTone: PluginStatusTone?

    public init(
        isGranted: Bool,
        footnote: String?,
        statusText: String? = nil,
        statusSystemImage: String? = nil,
        statusTone: PluginStatusTone? = nil
    ) {
        self.isGranted = isGranted
        self.footnote = footnote
        self.statusText = statusText
        self.statusSystemImage = statusSystemImage
        self.statusTone = statusTone
    }
}

public struct PluginPanelItem: Identifiable {
    public let id: String
    public let title: String
    public let iconName: String
    public let iconTint: Color
    public let controlStyle: PluginControlStyle
    public let menuActionBehavior: PluginMenuActionBehavior
    public let description: String
    public let helpText: String
    public let descriptionTone: PluginPanelDescriptionTone
    public let isOn: Bool
    public let isExpanded: Bool
    public let isEnabled: Bool
    public let detail: PluginPanelDetail?
    public let buttonActionID: String?
    public let buttonTitle: String?

    public init(
        id: String,
        title: String,
        iconName: String,
        iconTint: Color,
        controlStyle: PluginControlStyle,
        menuActionBehavior: PluginMenuActionBehavior,
        description: String,
        helpText: String,
        descriptionTone: PluginPanelDescriptionTone,
        isOn: Bool,
        isExpanded: Bool,
        isEnabled: Bool,
        detail: PluginPanelDetail?,
        buttonActionID: String?,
        buttonTitle: String?
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.iconTint = iconTint
        self.controlStyle = controlStyle
        self.menuActionBehavior = menuActionBehavior
        self.description = description
        self.helpText = helpText
        self.descriptionTone = descriptionTone
        self.isOn = isOn
        self.isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.detail = detail
        self.buttonActionID = buttonActionID
        self.buttonTitle = buttonTitle
    }
}

public enum PluginFeaturePresentation: Equatable {
    case featurePanel
    case componentPanel
    case featureAndComponentPanel
}

public struct PluginFeatureManagementItem: Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let iconName: String
    public let iconTint: Color
    public let isVisible: Bool
    public let isActive: Bool
    public let presentation: PluginFeaturePresentation
    public let category: String?
    public let releaseChannel: String?

    public init(
        id: String,
        title: String,
        description: String,
        iconName: String,
        iconTint: Color,
        isVisible: Bool,
        isActive: Bool,
        presentation: PluginFeaturePresentation,
        category: String? = nil,
        releaseChannel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.iconName = iconName
        self.iconTint = iconTint
        self.isVisible = isVisible
        self.isActive = isActive
        self.presentation = presentation
        self.category = category
        self.releaseChannel = releaseChannel
    }
}

public struct PluginPermissionCard: Identifiable {
    public let id: String
    public let pluginID: String
    public let permissionID: String
    public let title: String
    public let description: String
    public let iconSystemImage: String
    public let iconVisualScale: CGFloat
    public let statusText: String
    public let statusSystemImage: String
    public let statusTone: PluginStatusTone
    public let footnote: String?
    public let buttonTitle: String

    public init(
        id: String,
        pluginID: String,
        permissionID: String,
        title: String,
        description: String,
        iconSystemImage: String,
        iconVisualScale: CGFloat = 1,
        statusText: String,
        statusSystemImage: String,
        statusTone: PluginStatusTone,
        footnote: String?,
        buttonTitle: String
    ) {
        self.id = id
        self.pluginID = pluginID
        self.permissionID = permissionID
        self.title = title
        self.description = description
        self.iconSystemImage = iconSystemImage
        self.iconVisualScale = iconVisualScale
        self.statusText = statusText
        self.statusSystemImage = statusSystemImage
        self.statusTone = statusTone
        self.footnote = footnote
        self.buttonTitle = buttonTitle
    }
}
