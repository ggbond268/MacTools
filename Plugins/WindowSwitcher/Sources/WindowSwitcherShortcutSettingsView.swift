import SwiftUI
import MacToolsPluginKit

struct WindowSwitcherShortcutSettingsView: View {
    let context: PluginSettingsContext
    let localization: PluginLocalization
    let binding: (String) -> ShortcutBinding?
    @State private var customEditors: Set<String> = []
    @State private var errors: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            row(WindowSwitcherConstants.shortcutDefinitionID, currentApp: false)
            Divider()
            row(WindowSwitcherConstants.currentAppShortcutID, currentApp: true)
        }
    }

    @ViewBuilder
    private func row(_ id: String, currentApp: Bool) -> some View {
        if let item = context.shortcutItem(definitionID: id) {
            let presets: [(String, ShortcutBinding)] = currentApp
                ? [("⌘`", WindowSwitcherShortcutBindingStore.currentAppBinding)]
                : [("⌥Tab", WindowSwitcherShortcutBindingStore.defaultBinding), ("⌘Tab", WindowSwitcherShortcutBindingStore.legacyBinding)]
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Text(localization.string(currentApp ? "chooser.current" : "chooser.all", defaultValue: currentApp ? "当前应用" : "全部窗口"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .frame(minWidth: 110, alignment: .leading)
                    Spacer(minLength: 12)
                    Picker(item.title, selection: Binding(get: {
                        customEditors.contains(id) ? "custom" : presets.first { $0.1 == binding(id) }?.0 ?? "custom"
                    }, set: { value in
                        if let preset = presets.first(where: { $0.0 == value }) {
                            if case let .rejected(message) = context.recordShortcut(preset.1, for: item.id) { errors[id] = message }
                            else { errors[id] = nil; customEditors.remove(id) }
                        } else { customEditors.insert(id) }
                    })) {
                        ForEach(presets, id: \.0) { preset in Text(preset.0).tag(preset.0) }
                        Text(localization.string("settings.shortcutPreset.custom", defaultValue: "自定义快捷键")).tag("custom")
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(width: 150, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    PluginSettingsShortcutRecorderControl(title: item.title, displayText: item.bindingText,
                        canClear: item.canClear,
                        resetTitle: localization.string("settings.shortcut.reset", defaultValue: "恢复默认"),
                        clearTitle: localization.string("settings.shortcut.clear", defaultValue: "清除快捷键"),
                        onRecord: { value in
                            let result = context.recordShortcut(value, for: item.id)
                            if case .accepted = result { customEditors.remove(id); errors[id] = nil }
                            return result
                        }, onBeginRecording: { context.beginShortcutRecording(for: item.id) },
                        onReset: {
                            if case let .rejected(message) = context.recordShortcut(presets[0].1, for: item.id) { errors[id] = message }
                            else { customEditors.remove(id); errors[id] = nil }
                        },
                        onClear: { context.clearShortcut(for: item.id) })
                    .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth
                           + PluginSettingsTheme.Spacing.controlCluster + 22, alignment: .leading)
                }
                if let error = errors[id] ?? item.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        }
    }
}
