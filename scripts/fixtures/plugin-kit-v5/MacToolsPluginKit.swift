import SwiftUI

// Frozen client-facing declaration from plugins-1.2.0. This module is compiled
// without an implementation and linked against the current framework so the
// smoke test exercises the real cross-module value ABI.
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
}

public enum PluginStatusTone {
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
