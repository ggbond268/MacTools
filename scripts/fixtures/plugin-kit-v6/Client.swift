import MacToolsPluginKit

@MainActor
private final class LegacyPresetApplying: PluginActionShortcutPresetApplying {
    var previewActionShortcutPreset: ((
        Set<String>,
        [String: ShortcutBinding]
    ) -> PluginActionShortcutPresetPreview)?
    var applyActionShortcutPreset: ((Set<String>, [String: ShortcutBinding]) -> String?)?
}

@main
struct PluginKitV6CompatibilityClient {
    @MainActor
    static func main() {
        precondition(PluginKitCompatibility.currentVersion == 6)
        verifySettingsModels()
        let recorder = PluginShortcutRecorder(
            title: "Compatibility",
            displayText: "⌘K",
            onRecord: { _ in .accepted }
        )
        let labels = Mirror(reflecting: recorder).children.compactMap(\.label).map { label in
            label.hasPrefix("__") ? String(label.dropFirst()) : label
        }
        guard labels == [
            "title",
            "displayText",
            "placeholder",
            "minWidth",
            "onRecord",
            "onBeginRecording",
            "onEndRecording",
            "_isPresented",
            "_isHovered",
        ] else {
            fatalError("PluginShortcutRecorder v6 stored layout changed: \(labels)")
        }
        _ = recorder.body

        let binding = ShortcutBinding(keyCode: 40, modifiers: [.command, .shift])
        let definition = PluginShortcutDefinition(
            id: "compatibility",
            title: "Compatibility",
            description: "Frozen v6 shortcut definition",
            actionID: "run",
            scope: .global,
            defaultBinding: binding,
            isRequired: false,
            sharedBindingGroupID: "compatibility",
            settingsGroupID: "settings",
            settingsGroupTitle: "Settings",
            settingsGroupDescription: "Compatibility",
            settingsControlTitle: "Run",
            settingsControlSystemImage: "command"
        )
        guard definition.id == "compatibility",
              definition.defaultBinding?.keyCode == 40,
              definition.defaultBinding?.modifiers == [.command, .shift],
              definition.settingsControlSystemImage == "command" else {
            fatalError("PluginShortcutDefinition v6 value ABI changed")
        }

        let requirement = PluginPermissionRequirement(
            id: "accessibility",
            kind: .accessibility,
            title: "Accessibility",
            description: "Compatibility"
        )
        let state = PluginPermissionState(
            isGranted: false,
            footnote: "Grant access",
            statusText: "Required",
            statusSystemImage: "exclamationmark.triangle",
            statusTone: .caution
        )
        guard requirement.id == "accessibility",
              requirement.title == "Accessibility",
              !state.isGranted,
              state.footnote == "Grant access",
              state.statusText == "Required" else {
            fatalError("Plugin permission v6 value ABI changed")
        }

        let previewItem = PluginActionShortcutPresetPreviewItem(
            actionID: "run",
            currentBinding: binding,
            proposedBinding: nil
        )
        let previewLabels = Mirror(reflecting: previewItem).children.compactMap(\.label)
        guard previewLabels == [
            "actionID",
            "currentBinding",
            "proposedBinding",
            "conflictOwnerDescription",
        ] else {
            fatalError("PluginActionShortcutPresetPreviewItem v6 stored layout changed: \(previewLabels)")
        }

        let legacy = LegacyPresetApplying()
        let legacyPresetApplying: any PluginActionShortcutPresetApplying = legacy
        legacyPresetApplying.previewActionShortcutPreset = { _, _ in
            PluginActionShortcutPresetPreview(items: [previewItem])
        }
        legacyPresetApplying.applyActionShortcutPreset = { _, _ in nil }
        guard legacyPresetApplying.previewActionShortcutPreset?(["run"], [:]).items.count == 1,
              legacyPresetApplying.applyActionShortcutPreset?(["run"], [:]) == nil else {
            fatalError("Legacy PluginActionShortcutPresetApplying conformance failed")
        }
    }

    private static func verifySettingsModels() {
        let option = PluginSettingsOption(
            id: "choice", title: "Choice", description: "Details", descriptionTone: .caution
        )
        precondition(option.id == "choice" && option.title == "Choice")
        precondition(option.description == "Details" && option.descriptionTone == .caution)
        let confirmation = PluginSettingsConfirmation(
            title: "Confirm", message: "Continue?", confirmButtonTitle: "Continue",
            cancelButtonTitle: "Cancel"
        )
        let controls: [PluginSettingsControl] = [
            .toggle(isOn: true),
            .picker(selectionID: "choice", options: [option], style: .segmented),
            .choiceGroup(selectionID: "choice", options: [option]),
            .slider(value: 42, range: 0...100, step: 1, valueFormat: .percentage),
            .textField(value: "text", prompt: "Prompt", isRequired: true),
            .secureField(value: "secret", prompt: nil, isRequired: false),
            .action(title: "Run", role: .prominent),
            .confirmationAction(title: "Remove", role: .destructive, confirmation: confirmation),
            .status(text: "Ready", systemImage: "checkmark", tone: .positive, actionTitle: "Open"),
        ]
        let rows = controls.enumerated().map { index, control in
            PluginSettingsRow(
                id: "row-\(index)", title: "Row \(index)", description: "Description",
                systemImage: "gear", keywords: ["settings"], help: "Help",
                helpItems: ["First", "Second"], helpTone: .caution, error: "Error",
                isEnabled: false, isVisible: true, control: control
            )
        }
        let caseNames = [
            "toggle", "picker", "choiceGroup", "slider", "textField", "secureField",
            "action", "confirmationAction", "status",
        ]
        for (index, row) in rows.enumerated() {
            precondition(Mirror(reflecting: row).children.compactMap(\.label) == [
                "id", "title", "description", "systemImage", "keywords", "help",
                "helpItems", "helpTone", "error", "isEnabled", "isVisible", "control",
            ])
            precondition(Mirror(reflecting: row.control).children.first?.label == caseNames[index])
            precondition(row.id == "row-\(index)" && row.title == "Row \(index)")
            precondition(row.description == "Description" && row.systemImage == "gear")
            precondition(row.keywords == ["settings"] && row.help == "Help")
            precondition(row.helpItems == ["First", "Second"] && row.helpTone == .caution)
            precondition(row.error == "Error" && !row.isEnabled && row.isVisible)
            switch (index, row.control) {
            case let (0, .toggle(isOn)): precondition(isOn)
            case let (1, .picker(selectionID, options, style)):
                precondition(selectionID == "choice" && options == [option])
                guard case .segmented = style else { fatalError("Picker style ABI changed") }
                precondition(String(describing: style) == "segmented")
            case let (2, .choiceGroup(selectionID, options)):
                precondition(selectionID == "choice" && options == [option])
            case let (3, .slider(value, range, step, format)):
                precondition(value == 42 && range == 0...100 && step == 1)
                precondition(format?.suffix == "%")
            case let (4, .textField(value, prompt, required)):
                precondition(value == "text" && prompt == "Prompt" && required)
            case let (5, .secureField(value, prompt, required)):
                precondition(value == "secret" && prompt == nil && !required)
            case let (6, .action(title, role)):
                precondition(title == "Run" && role == .prominent)
            case let (7, .confirmationAction(title, role, value)):
                precondition(title == "Remove" && role == .destructive && value == confirmation)
            case let (8, .status(text, image, tone, action)):
                precondition(text == "Ready" && image == "checkmark")
                precondition(tone == .positive && action == "Open")
            default: fatalError("PluginSettingsControl v6 case ABI changed")
            }
        }
        let defaults = PluginSettingsRow(id: "default", title: "Default", control: .toggle(isOn: false))
        precondition(defaults.helpItems.isEmpty && defaults.helpTone == .neutral)
        precondition(defaults.isEnabled && defaults.isVisible && defaults.error == nil)
    }
}
