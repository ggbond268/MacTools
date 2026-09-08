import SwiftUI

public enum PluginKitCompatibility {
    public static let currentVersion = 6
}

// Frozen client-facing declarations for the PluginKit v6 / MacTools 1.3.0 ABI.
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
