import Foundation
import SwiftUI

/// A plugin settings page is a snapshot of the plugin's current settings state.
///
/// The host owns the page shell, navigation, header, scrolling, permissions,
/// shortcuts, search, and platform styling. Plugins provide either a declarative
/// form or a task-oriented workspace.
public struct PluginSettingsPage {
    public let description: String?
    public let body: PluginSettingsBody
    public let visibilityHandler: ((Bool) -> Void)?

    public init(
        description: String? = nil,
        body: PluginSettingsBody,
        visibilityHandler: ((Bool) -> Void)? = nil
    ) {
        self.description = description
        self.body = body
        self.visibilityHandler = visibilityHandler
    }

    public static func form(
        description: String? = nil,
        sections: [PluginSettingsSection]
    ) -> PluginSettingsPage {
        PluginSettingsPage(
            description: description,
            body: .form(sections)
        )
    }

    public static func workspace<Content: View>(
        description: String? = nil,
        scrolling: PluginSettingsWorkspaceScrolling = .selfManaged,
        @ViewBuilder content: @escaping (PluginSettingsContext) -> Content
    ) -> PluginSettingsPage {
        PluginSettingsPage(
            description: description,
            body: .workspace(PluginSettingsWorkspace(scrolling: scrolling, content: content))
        )
    }

    /// Registers page-level visibility work. The host invokes this for the
    /// settings page itself, never for lazily created Form sections.
    public func onVisibilityChange(
        _ handler: @escaping (Bool) -> Void
    ) -> PluginSettingsPage {
        PluginSettingsPage(
            description: description,
            body: body,
            visibilityHandler: handler
        )
    }
}

public enum PluginSettingsBody {
    case form([PluginSettingsSection])
    case workspace(PluginSettingsWorkspace)

    public var layout: PluginSettingsLayout {
        switch self {
        case .form:
            return .form
        case .workspace:
            return .workspace
        }
    }

    public var integratedShortcutGroupIDs: Set<String> {
        guard case let .form(sections) = self else {
            return []
        }

        return sections.reduce(into: Set<String>()) { result, section in
            guard section.isVisible else {
                return
            }
            switch section.content {
            case let .shortcutGroup(groupID):
                result.insert(groupID)
            case let .custom(customContent):
                result.formUnion(customContent.embeddedShortcutGroupIDs)
            case .rows:
                break
            }
        }
    }
}

public enum PluginSettingsLayout: String, Codable, CaseIterable, Sendable {
    case form
    case workspace
}

public struct PluginSettingsSection: Identifiable {
    public let id: String
    public let title: String?
    public let systemImage: String?
    public let footer: String?
    public let presentation: PluginSettingsSectionPresentation
    public let isVisible: Bool
    public let headerAccessory: PluginSettingsSectionAccessory?
    public let content: PluginSettingsSectionContent

    public init(
        id: String,
        title: String? = nil,
        systemImage: String? = nil,
        footer: String? = nil,
        presentation: PluginSettingsSectionPresentation = .standard,
        isVisible: Bool = true,
        rows: [PluginSettingsRow]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.presentation = presentation
        self.isVisible = isVisible
        self.headerAccessory = nil
        self.content = .rows(rows)
    }

    public init<Content: View>(
        id: String,
        title: String? = nil,
        systemImage: String? = nil,
        footer: String? = nil,
        presentation: PluginSettingsSectionPresentation = .standard,
        isVisible: Bool = true,
        embeddedShortcutGroupIDs: Set<String> = [],
        @ViewBuilder content: @escaping (PluginSettingsContext) -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.presentation = presentation
        self.isVisible = isVisible
        self.headerAccessory = nil
        self.content = .custom(
            PluginSettingsCustomContent(
                embeddedShortcutGroupIDs: embeddedShortcutGroupIDs,
                content: content
            )
        )
    }

    public static func shortcutGroup(
        _ groupID: String,
        title: String? = nil,
        systemImage: String? = "command",
        footer: String? = nil
    ) -> PluginSettingsSection {
        PluginSettingsSection(
            id: "shortcut-group.\(groupID)",
            title: title,
            systemImage: systemImage,
            footer: footer,
            presentation: .standard,
            isVisible: true,
            headerAccessory: nil,
            content: .shortcutGroup(groupID)
        )
    }

    /// Adds a trailing action or status view to the host-rendered section header.
    /// The closure remains lazy and receives the same settings context as the
    /// section content.
    public func headerAccessory<Accessory: View>(
        @ViewBuilder _ accessory: @escaping (PluginSettingsContext) -> Accessory
    ) -> PluginSettingsSection {
        PluginSettingsSection(
            id: id,
            title: title,
            systemImage: systemImage,
            footer: footer,
            presentation: presentation,
            isVisible: isVisible,
            headerAccessory: PluginSettingsSectionAccessory(content: accessory),
            content: content
        )
    }

    private init(
        id: String,
        title: String?,
        systemImage: String?,
        footer: String?,
        presentation: PluginSettingsSectionPresentation,
        isVisible: Bool,
        headerAccessory: PluginSettingsSectionAccessory?,
        content: PluginSettingsSectionContent
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.presentation = presentation
        self.isVisible = isVisible
        self.headerAccessory = headerAccessory
        self.content = content
    }
}

/// Controls only the placement of custom content inside the system Form card.
/// Standard content keeps the native row insets. Tables and internally padded
/// row collections can opt into edge-to-edge placement without drawing their
/// own outer card.
public enum PluginSettingsSectionPresentation: Sendable {
    case standard
    case edgeToEdge
}

public struct PluginSettingsSectionAccessory {
    public let makeView: (PluginSettingsContext) -> AnyView

    public init<Content: View>(
        @ViewBuilder content: @escaping (PluginSettingsContext) -> Content
    ) {
        self.makeView = { context in AnyView(content(context)) }
    }
}

public enum PluginSettingsSectionContent {
    case rows([PluginSettingsRow])
    case custom(PluginSettingsCustomContent)
    case shortcutGroup(String)
}

public struct PluginSettingsCustomContent {
    public let embeddedShortcutGroupIDs: Set<String>
    public let makeView: (PluginSettingsContext) -> AnyView

    public init<Content: View>(
        embeddedShortcutGroupIDs: Set<String> = [],
        @ViewBuilder content: @escaping (PluginSettingsContext) -> Content
    ) {
        self.embeddedShortcutGroupIDs = embeddedShortcutGroupIDs
        self.makeView = { context in AnyView(content(context)) }
    }
}

public struct PluginSettingsWorkspace {
    public let scrolling: PluginSettingsWorkspaceScrolling
    public let makeView: (PluginSettingsContext) -> AnyView

    public init<Content: View>(
        scrolling: PluginSettingsWorkspaceScrolling = .selfManaged,
        @ViewBuilder content: @escaping (PluginSettingsContext) -> Content
    ) {
        self.scrolling = scrolling
        self.makeView = { context in AnyView(content(context)) }
    }
}

public enum PluginSettingsWorkspaceScrolling: Sendable {
    /// The host supplies the only vertical ScrollView and standard page insets.
    case host
    /// The workspace owns split views, editors, lists, or other scrolling.
    case selfManaged
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

public enum PluginSettingsAction: Equatable, Sendable {
    public enum ChangePhase: Equatable, Sendable {
        case changed
        case committed
    }

    case setBoolean(controlID: String, value: Bool)
    case setSelection(controlID: String, optionID: String)
    case setNumber(controlID: String, value: Double, phase: ChangePhase)
    case setText(controlID: String, value: String, phase: ChangePhase)
    case invoke(controlID: String)

    public var controlID: String {
        switch self {
        case let .setBoolean(controlID, _),
             let .setSelection(controlID, _),
             let .setNumber(controlID, _, _),
             let .setText(controlID, _, _),
             let .invoke(controlID):
            return controlID
        }
    }
}

public struct PluginSettingsContext {
    public let pluginID: String
    public let shortcutItems: [ShortcutSettingsItem]

    private let recordShortcutHandler: (String, ShortcutBinding) -> String?
    private let beginShortcutRecordingHandler: (String) -> Void
    private let clearShortcutHandler: (String) -> Void
    private let resetShortcutHandler: (String) -> Void

    public init(
        pluginID: String,
        shortcutItems: [ShortcutSettingsItem] = [],
        recordShortcut: @escaping (String, ShortcutBinding) -> String? = { _, _ in nil },
        beginShortcutRecording: @escaping (String) -> Void = { _ in },
        clearShortcut: @escaping (String) -> Void = { _ in },
        resetShortcut: @escaping (String) -> Void = { _ in }
    ) {
        self.pluginID = pluginID
        self.shortcutItems = shortcutItems
        self.recordShortcutHandler = recordShortcut
        self.beginShortcutRecordingHandler = beginShortcutRecording
        self.clearShortcutHandler = clearShortcut
        self.resetShortcutHandler = resetShortcut
    }

    public func shortcutItem(definitionID: String) -> ShortcutSettingsItem? {
        shortcutItems.first { $0.id == "\(pluginID).shortcut.\(definitionID)" }
    }

    public func recordShortcut(
        _ binding: ShortcutBinding,
        for itemID: String
    ) -> PluginShortcutRecordingResult {
        PluginShortcutRecordingResult.from(
            errorMessage: recordShortcutHandler(itemID, binding)
        )
    }

    public func beginShortcutRecording(for itemID: String) {
        beginShortcutRecordingHandler(itemID)
    }

    public func clearShortcut(for itemID: String) {
        clearShortcutHandler(itemID)
    }

    public func resetShortcut(for itemID: String) {
        resetShortcutHandler(itemID)
    }
}

public enum PluginSettingsValidationError: Error, Equatable, CustomStringConvertible {
    case emptySectionID
    case duplicateSectionID(String)
    case emptyRowID(sectionID: String)
    case duplicateRowID(String)
    case emptyOptionID(rowID: String)
    case duplicateOptionID(rowID: String, optionID: String)
    case missingPickerSelection(rowID: String, selectionID: String)
    case invalidSliderRange(rowID: String)
    case sliderValueOutOfRange(rowID: String)
    case invalidSliderStep(rowID: String)
    case invalidSliderValueFormat(rowID: String)
    case emptyShortcutGroupID(sectionID: String)
    case duplicateShortcutGroupID(String)
    case missingShortcutGroup(String)

    public var description: String {
        switch self {
        case .emptySectionID:
            return "Settings section IDs must not be empty."
        case let .duplicateSectionID(id):
            return "Duplicate settings section ID: \(id)."
        case let .emptyRowID(sectionID):
            return "Settings row IDs must not be empty in section \(sectionID)."
        case let .duplicateRowID(id):
            return "Duplicate settings row ID: \(id)."
        case let .emptyOptionID(rowID):
            return "Picker option IDs must not be empty in row \(rowID)."
        case let .duplicateOptionID(rowID, optionID):
            return "Duplicate picker option ID \(optionID) in row \(rowID)."
        case let .missingPickerSelection(rowID, selectionID):
            return "Picker row \(rowID) selects missing option \(selectionID)."
        case let .invalidSliderRange(rowID):
            return "Slider row \(rowID) has an invalid range."
        case let .sliderValueOutOfRange(rowID):
            return "Slider row \(rowID) has a value outside its range."
        case let .invalidSliderStep(rowID):
            return "Slider row \(rowID) must use a positive step."
        case let .invalidSliderValueFormat(rowID):
            return "Slider row \(rowID) must use between 0 and 12 fraction digits."
        case let .emptyShortcutGroupID(sectionID):
            return "Shortcut group IDs must not be empty in section \(sectionID)."
        case let .duplicateShortcutGroupID(groupID):
            return "Shortcut group \(groupID) is placed more than once."
        case let .missingShortcutGroup(groupID):
            return "Shortcut group \(groupID) does not exist."
        }
    }
}

public enum PluginSettingsValidator {
    public static func validate(
        _ page: PluginSettingsPage,
        availableShortcutGroupIDs: Set<String> = []
    ) throws {
        guard case let .form(sections) = page.body else {
            return
        }

        var sectionIDs: Set<String> = []
        var rowIDs: Set<String> = []
        var shortcutGroupIDs: Set<String> = []

        for section in sections {
            guard !section.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginSettingsValidationError.emptySectionID
            }
            guard sectionIDs.insert(section.id).inserted else {
                throw PluginSettingsValidationError.duplicateSectionID(section.id)
            }

            switch section.content {
            case let .rows(rows):
                for row in rows {
                    guard !row.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PluginSettingsValidationError.emptyRowID(sectionID: section.id)
                    }
                    guard rowIDs.insert(row.id).inserted else {
                        throw PluginSettingsValidationError.duplicateRowID(row.id)
                    }
                    try validate(row)
                }
            case let .custom(customContent):
                for groupID in customContent.embeddedShortcutGroupIDs {
                    guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PluginSettingsValidationError.emptyShortcutGroupID(sectionID: section.id)
                    }
                    guard shortcutGroupIDs.insert(groupID).inserted else {
                        throw PluginSettingsValidationError.duplicateShortcutGroupID(groupID)
                    }
                    guard availableShortcutGroupIDs.contains(groupID) else {
                        throw PluginSettingsValidationError.missingShortcutGroup(groupID)
                    }
                }
            case let .shortcutGroup(groupID):
                guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PluginSettingsValidationError.emptyShortcutGroupID(sectionID: section.id)
                }
                guard shortcutGroupIDs.insert(groupID).inserted else {
                    throw PluginSettingsValidationError.duplicateShortcutGroupID(groupID)
                }
                guard availableShortcutGroupIDs.contains(groupID) else {
                    throw PluginSettingsValidationError.missingShortcutGroup(groupID)
                }
            }
        }
    }

    private static func validate(_ row: PluginSettingsRow) throws {
        switch row.control {
        case let .picker(selectionID, options, _),
             let .choiceGroup(selectionID, options):
            var optionIDs: Set<String> = []
            for option in options {
                guard !option.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PluginSettingsValidationError.emptyOptionID(rowID: row.id)
                }
                guard optionIDs.insert(option.id).inserted else {
                    throw PluginSettingsValidationError.duplicateOptionID(
                        rowID: row.id,
                        optionID: option.id
                    )
                }
            }
            guard optionIDs.contains(selectionID) else {
                throw PluginSettingsValidationError.missingPickerSelection(
                    rowID: row.id,
                    selectionID: selectionID
                )
            }
        case let .slider(value, range, step, valueFormat):
            guard range.lowerBound.isFinite,
                  range.upperBound.isFinite,
                  range.lowerBound <= range.upperBound
            else {
                throw PluginSettingsValidationError.invalidSliderRange(rowID: row.id)
            }
            guard range.contains(value) else {
                throw PluginSettingsValidationError.sliderValueOutOfRange(rowID: row.id)
            }
            if let step, !step.isFinite || step <= 0 {
                throw PluginSettingsValidationError.invalidSliderStep(rowID: row.id)
            }
            if let valueFormat, !(0...12).contains(valueFormat.fractionDigits) {
                throw PluginSettingsValidationError.invalidSliderValueFormat(rowID: row.id)
            }
        case .toggle, .textField, .secureField, .action, .confirmationAction, .status:
            break
        }
    }
}
