import SwiftUI

public enum PluginKitCompatibility {
    public static let currentVersion = 7
}

// Frozen client-facing declarations for the PluginKit v7 / MacTools 1.3.1 ABI.
// Compile only this module interface, then link the client against the real
// framework. Keep this fixture independent of subsequent production changes.
public enum ShortcutScope {
    case global
    case whilePluginActive
}

public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
    public init(rawValue: UInt8) { self.rawValue = rawValue }
}

public struct ShortcutBinding: Hashable, Codable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        fatalError("The compatibility client must link this initializer from the current framework")
    }
}

public struct PluginShortcutDefinition: Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let actionID: String
    public let scope: ShortcutScope
    public let defaultBinding: ShortcutBinding?
    public let isRequired: Bool
    public let sharedBindingGroupID: String?
    public let settingsGroupID: String?
    public let settingsGroupTitle: String?
    public let settingsGroupDescription: String?
    public let settingsControlTitle: String?
    public let settingsControlSystemImage: String?

    public init(
        id: String,
        title: String,
        description: String,
        actionID: String,
        scope: ShortcutScope,
        defaultBinding: ShortcutBinding?,
        isRequired: Bool,
        sharedBindingGroupID: String? = nil,
        settingsGroupID: String? = nil,
        settingsGroupTitle: String? = nil,
        settingsGroupDescription: String? = nil,
        settingsControlTitle: String? = nil,
        settingsControlSystemImage: String? = nil
    ) {
        fatalError("The compatibility client must link this initializer from the current framework")
    }
}

public enum PluginPermissionKind {
    case accessibility
    case inputMonitoring
    case calendarFullAccess
    case automation
    case screenRecording
    case finderExtension
}

public enum PluginStatusTone: Equatable, Sendable {
    case neutral
    case positive
    case caution
}

public struct PluginPermissionRequirement: Identifiable {
    public let id: String
    public let kind: PluginPermissionKind
    public let title: String
    public let description: String

    public init(id: String, kind: PluginPermissionKind, title: String, description: String) {
        fatalError("The compatibility client must link this initializer from the current framework")
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
        fatalError("The compatibility client must link this initializer from the current framework")
    }
}

public struct PluginActionShortcutPresetPreviewItem: Equatable, Sendable {
    public let actionID: String
    public let currentBinding: ShortcutBinding?
    public let proposedBinding: ShortcutBinding?
    public let conflictOwnerDescription: String?

    public init(
        actionID: String,
        currentBinding: ShortcutBinding?,
        proposedBinding: ShortcutBinding?,
        conflictOwnerDescription: String? = nil
    ) {
        fatalError("The compatibility client must link this initializer from the current framework")
    }
}

public struct PluginActionShortcutPresetPreview: Equatable, Sendable {
    public let items: [PluginActionShortcutPresetPreviewItem]
    public let errorMessage: String?

    public init(
        items: [PluginActionShortcutPresetPreviewItem],
        errorMessage: String? = nil
    ) {
        fatalError("The compatibility client must link this initializer from the current framework")
    }
}

@MainActor
public protocol PluginActionShortcutPresetApplying: AnyObject {
    var previewActionShortcutPreset: ((
        _ managedActionIDs: Set<String>,
        _ bindingsByActionID: [String: ShortcutBinding]
    ) -> PluginActionShortcutPresetPreview)? { get set }
    var applyActionShortcutPreset: ((
        _ managedActionIDs: Set<String>,
        _ bindingsByActionID: [String: ShortcutBinding]
    ) -> String?)? { get set }
}

public enum PluginShortcutRecordingResult: Equatable {
    case accepted
    case rejected(String)
}

public struct PluginShortcutRecorder: View {
    public let title: String
    public let displayText: String
    public let placeholder: String
    public let minWidth: CGFloat
    public let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    public let onBeginRecording: (() -> Void)?
    public let onEndRecording: (() -> Void)?

    @State private var isPresented = false
    @State private var isHovered = false

    public init(
        title: String,
        displayText: String,
        placeholder: String = "Not set",
        minWidth: CGFloat = 90,
        onRecord: @escaping (ShortcutBinding) -> PluginShortcutRecordingResult,
        onBeginRecording: (() -> Void)? = nil,
        onEndRecording: (() -> Void)? = nil
    ) {
        fatalError("The compatibility client must link this initializer from the current framework")
    }

    public var body: some View {
        fatalError("The compatibility client must link this getter from the current framework")
    }
}

public struct PluginSettingsRow: Identifiable {
    public let id: String
    public let title: String
    public let description: String?
    public let systemImage: String?
    public let keywords: [String]
    public let help: String?
    public let helpItems: [String]
    public let helpTone: PluginStatusTone
    public let error: String?
    public let isEnabled: Bool
    public let isVisible: Bool
    public let control: PluginSettingsControl

    public init(
        id: String,
        title: String,
        description: String? = nil,
        systemImage: String? = nil,
        keywords: [String] = [],
        help: String? = nil,
        helpItems: [String] = [],
        helpTone: PluginStatusTone = .neutral,
        error: String? = nil,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        control: PluginSettingsControl
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.keywords = keywords
        self.help = help
        self.helpItems = helpItems
        self.helpTone = helpTone
        self.error = error
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.control = control
    }
}

public enum PluginSettingsControl {
    case toggle(isOn: Bool)
    case picker(
        selectionID: String,
        options: [PluginSettingsOption],
        style: PluginSettingsPickerStyle
    )
    case choiceGroup(selectionID: String, options: [PluginSettingsOption])
    case slider(
        value: Double,
        range: ClosedRange<Double>,
        step: Double?,
        valueFormat: PluginSettingsSliderValueFormat?
    )
    case textField(value: String, prompt: String?, isRequired: Bool)
    case secureField(value: String, prompt: String?, isRequired: Bool)
    case action(title: String, role: PluginSettingsActionRole)
    case confirmationAction(
        title: String,
        role: PluginSettingsActionRole,
        confirmation: PluginSettingsConfirmation
    )
    case status(
        text: String,
        systemImage: String,
        tone: PluginStatusTone,
        actionTitle: String?
    )
}

public struct PluginSettingsOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let descriptionTone: PluginStatusTone

    public init(
        id: String,
        title: String,
        description: String? = nil,
        descriptionTone: PluginStatusTone = .neutral
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.descriptionTone = descriptionTone
    }
}

public enum PluginSettingsPickerStyle: Sendable {
    case automatic
    case menu
    case segmented
}

/// Describes a slider readout without freezing it to the page snapshot's value.
/// The host formats its local interaction value so labels stay live while a
/// plugin defers persistence and page rebuilding until the drag is committed.
public struct PluginSettingsSliderValueFormat: Equatable, Sendable {
    public static let percentage = PluginSettingsSliderValueFormat(suffix: "%")

    public let prefix: String
    public let suffix: String
    public let fractionDigits: Int

    public init(
        prefix: String = "",
        suffix: String = "",
        fractionDigits: Int = 0
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.fractionDigits = fractionDigits
    }

    public func text(
        for value: Double,
        locale: Locale = .current
    ) -> String {
        let number = value.formatted(
            .number
                .locale(locale)
                .precision(.fractionLength(fractionDigits))
        )
        return "\(prefix)\(number)\(suffix)"
    }
}

public enum PluginSettingsActionRole: Equatable, Sendable {
    case normal
    case prominent
    case destructive
}

public struct PluginSettingsConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmButtonTitle: String
    public let cancelButtonTitle: String

    public init(
        title: String,
        message: String,
        confirmButtonTitle: String,
        cancelButtonTitle: String
    ) {
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
    }
}

// Frozen multi-view item ABI. Do not regenerate this from production sources.
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

public struct PluginPanelRowDescriptor {
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

public enum PluginPanelWidgetGrid: Int, Sendable {
    case standard = 4
    case compact = 5
}

public struct PluginPanelWidgetSpan: Equatable, Hashable, Sendable {
    public static let maximumWidth = 4

    public let width: Int
    public let height: Int
    public let grid: PluginPanelWidgetGrid

    public init?(width: Int, height: Int, grid: PluginPanelWidgetGrid = .standard) {
        guard Self.isValid(width: width, height: height, grid: grid) else {
            return nil
        }

        self.width = width
        self.height = height
        self.grid = grid
    }

    private init(uncheckedWidth width: Int, height: Int) {
        self.width = width
        self.height = height
        self.grid = .standard
    }

    public static let oneByOne = PluginPanelWidgetSpan(uncheckedWidth: 1, height: 1)
    public static let oneByTwo = PluginPanelWidgetSpan(uncheckedWidth: 1, height: 2)
    public static let twoByOne = PluginPanelWidgetSpan(uncheckedWidth: 2, height: 1)
    public static let twoByTwo = PluginPanelWidgetSpan(uncheckedWidth: 2, height: 2)
    public static let fourByTwo = PluginPanelWidgetSpan(uncheckedWidth: 4, height: 2)

    public static func isValid(width: Int, height: Int, grid: PluginPanelWidgetGrid = .standard) -> Bool {
        (1...grid.rawValue).contains(width) && height >= 1
    }
}

public struct PluginPanelWidgetLayoutMetrics: Equatable, Sendable {
    public static let cardCornerRadius: CGFloat = 12
    public static let compactSpacing: CGFloat = 10

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

    public static let `default`: PluginPanelWidgetLayoutMetrics = {
        let originalCellHeight: CGFloat = 94
        let verticalSpacing: CGFloat = 8
        return PluginPanelWidgetLayoutMetrics(
            columns: PluginPanelWidgetSpan.maximumWidth,
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

    public func itemWidth(for span: PluginPanelWidgetSpan) -> CGFloat {
        let spacing = span.grid == .compact ? Self.compactSpacing : horizontalSpacing
        return (gridWidth + spacing) * CGFloat(span.width) / CGFloat(span.grid.rawValue) - spacing
    }

    public var compactCellSize: CGSize {
        let width = itemWidth(for: PluginPanelWidgetSpan(width: 1, height: 1, grid: .compact)!)
        return CGSize(width: width, height: itemHeight(forSpanHeight: heightSpan(fittingContentHeight: 64)))
    }

    public var compactRowSpacing: CGFloat { Self.compactSpacing }

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

public struct PluginPanelWidgetDescriptor {
    public let span: PluginPanelWidgetSpan

    public init(span: PluginPanelWidgetSpan) {
        self.span = span
    }
}

public struct PluginPanelWidgetState {
    public let subtitle: String
    public let isActive: Bool
    public let isEnabled: Bool
    public let isAvailable: Bool
    public let errorMessage: String?

    public init(
        subtitle: String,
        isActive: Bool,
        isEnabled: Bool,
        isAvailable: Bool,
        errorMessage: String?
    ) {
        self.subtitle = subtitle
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
        self.errorMessage = errorMessage
    }
}

public struct PluginPanelWidgetContext {
    public let pluginID: String
    public let itemID: String
    public let placementID: UUID?
    public let dismiss: () -> Void
    public let presentDetail: (String) -> Void

    public var isPreview: Bool { placementID == nil }

    public init(pluginID: String, itemID: String, placementID: UUID?,
                dismiss: @escaping () -> Void, presentDetail: @escaping (String) -> Void = { _ in }) {
        self.pluginID = pluginID
        self.itemID = itemID
        self.placementID = placementID
        self.dismiss = dismiss
        self.presentDetail = presentDetail
    }
}

public struct PluginPanelRowState {
    public var indicator: PluginPanelRowIndicator?
    public var compactIndicator: PluginPanelRowCompactIndicator?
    public let subtitle: String
    public let isOn: Bool
    public let isEnabled: Bool
    public let isAvailable: Bool
    public let detail: PluginPanelDetail?
    public let errorMessage: String?

    public init(
        subtitle: String,
        isOn: Bool,
        isEnabled: Bool,
        isAvailable: Bool,
        detail: PluginPanelDetail?,
        errorMessage: String?
    ) {
        self.subtitle = subtitle
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
        self.detail = detail
        self.errorMessage = errorMessage
    }
}

public struct PluginPanelRowIndicator: Equatable {
    public let text: String
    public let systemImage: String

    public init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

public struct PluginPanelRowCompactIndicator: Equatable {
    public let icons: [PluginPanelRowIndicatorIcon]

    public init(icons: [PluginPanelRowIndicatorIcon]) {
        precondition(!icons.isEmpty, "Primary panel indicators require at least one icon.")
        self.icons = icons
    }
}

public struct PluginPanelRowIndicatorIcon: Equatable {
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



/// The host owns layout; plugins choose one of its supported renderers.
public enum PluginPanelItemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case row
    case widget
}

/// A suggestion applied once when an item is first discovered, never on refresh.
public enum PluginPanelInitialPlacement: String, Codable, Hashable, Sendable {
    case dashboard
    case featurePanel
}

/// A lightweight snapshot. IDs and renderer kinds stay stable across updates.
/// Titles, states, and widget dimensions may change after `onStateChange`.
@MainActor
public struct PluginPanelItem: Identifiable {
    public let id: String
    public let title: String?
    public let description: String?
    public let systemImage: String?
    public let iconTint: Color?
    public let initialPlacement: PluginPanelInitialPlacement?
    public let content: PluginPanelContent
    public let visibilityHandler: ((Bool) -> Void)?

    public var kind: PluginPanelItemKind {
        switch content {
        case .row: .row
        case .widget: .widget
        }
    }

    public init(
        id: String,
        title: String? = nil,
        description: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        initialPlacement: PluginPanelInitialPlacement? = nil,
        content: PluginPanelContent,
        visibilityHandler: ((Bool) -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.initialPlacement = initialPlacement
        self.content = content
        self.visibilityHandler = visibilityHandler
    }

    public static func row(
        id: String,
        title: String? = nil,
        description: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        initialPlacement: PluginPanelInitialPlacement? = nil,
        descriptor: PluginPanelRowDescriptor,
        state: PluginPanelRowState,
        action: @escaping (PluginPanelAction) -> Void
    ) -> Self {
        Self(id: id, title: title, description: description, systemImage: systemImage,
             iconTint: iconTint, initialPlacement: initialPlacement,
             content: .row(PluginPanelRow(descriptor: descriptor, state: state, action: action)))
    }

    public static func widget<Content: View>(
        id: String,
        title: String? = nil,
        description: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        initialPlacement: PluginPanelInitialPlacement? = nil,
        descriptor: PluginPanelWidgetDescriptor,
        state: PluginPanelWidgetState,
        detail: ((String, @escaping () -> Void) -> PluginPanelDetailContent?)? = nil,
        @ViewBuilder content: @escaping (PluginPanelWidgetContext) -> Content
    ) -> Self {
        Self(id: id, title: title, description: description, systemImage: systemImage,
             iconTint: iconTint, initialPlacement: initialPlacement,
             content: .widget(PluginPanelWidget(
                descriptor: descriptor, state: state, detail: detail,
                content: { AnyView(content($0)) }
             )))
    }

    /// Aggregated across placements in the presented panel. Preview creation and
    /// viewport mounting never start or stop plugin business work.
    public func onVisibilityChange(_ handler: @escaping (Bool) -> Void) -> Self {
        Self(id: id, title: title, description: description, systemImage: systemImage,
             iconTint: iconTint, initialPlacement: initialPlacement,
             content: content, visibilityHandler: handler)
    }
}

@MainActor
public enum PluginPanelContent {
    case row(PluginPanelRow)
    case widget(PluginPanelWidget)
}

@MainActor
public struct PluginPanelRow {
    public let descriptor: PluginPanelRowDescriptor
    public let state: PluginPanelRowState
    public let action: (PluginPanelAction) -> Void

    public init(descriptor: PluginPanelRowDescriptor, state: PluginPanelRowState,
                action: @escaping (PluginPanelAction) -> Void) {
        self.descriptor = descriptor
        self.state = state
        self.action = action
    }
}

@MainActor
public struct PluginPanelWidget {
    public let descriptor: PluginPanelWidgetDescriptor
    public let state: PluginPanelWidgetState
    public let makeDetail: ((String, @escaping () -> Void) -> PluginPanelDetailContent?)?
    public let makeView: (PluginPanelWidgetContext) -> AnyView

    public init(descriptor: PluginPanelWidgetDescriptor, state: PluginPanelWidgetState,
                detail: ((String, @escaping () -> Void) -> PluginPanelDetailContent?)? = nil,
                content: @escaping (PluginPanelWidgetContext) -> AnyView) {
        self.descriptor = descriptor
        self.state = state
        self.makeDetail = detail
        self.makeView = content
    }
}

public enum PluginPanelIconControl: Equatable, Sendable {
    case toggle
    case button
}

public extension PluginPanelItem {
    static func iconWidget(
        id: String,
        title: String,
        systemImage: String,
        control: PluginPanelIconControl,
        state: PluginPanelRowState,
        menuActionBehavior: PluginMenuActionBehavior,
        action: @escaping (PluginPanelAction) -> Void
    ) -> Self {
        fatalError("Declaration-only ABI fixture; the client links the host framework implementation.")
    }
}

public struct PluginPanelDetailContent {
    public let id: String
    public let title: String
    public let content: AnyView

    public init(id: String, title: String, content: AnyView) {
        self.id = id
        self.title = title
        self.content = content
    }
}
