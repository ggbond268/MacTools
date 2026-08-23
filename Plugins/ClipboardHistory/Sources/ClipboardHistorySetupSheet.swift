import MacToolsPluginKit
import SwiftUI

enum ClipboardHistorySetupDestination: String, Identifiable {
    case guide

    var id: String { rawValue }
}

@MainActor
struct ClipboardHistorySetupSheet: View {
    private enum Step: Int, CaseIterable {
        case storage
        case primaryShortcuts
        case sensitiveCopy
        case ready
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller: ClipboardHistoryController
    @ObservedObject private var settings: ClipboardHistorySettingsStore
    private let localization: PluginLocalization
    private let settingsContext: PluginSettingsContext
    @State private var step: Step = .storage
    @State private var shortcutBindingTexts: [String: String]
    @State private var assignedShortcutIDs: Set<String>

    init(
        controller: ClipboardHistoryController,
        localization: PluginLocalization,
        settingsContext: PluginSettingsContext
    ) {
        self.controller = controller
        self.localization = localization
        self.settingsContext = settingsContext
        _settings = ObservedObject(wrappedValue: controller.settings)
        var bindingTexts: [String: String] = [:]
        var assignedIDs: Set<String> = []
        for item in settingsContext.shortcutItems {
            bindingTexts[item.id] = item.bindingText
            if item.canClear {
                assignedIDs.insert(item.id)
            }
        }
        for item in settingsContext.actionShortcutItems {
            let key = Self.actionShortcutKey(item.actionID)
            bindingTexts[key] = item.bindingText
            if item.canClear {
                assignedIDs.insert(key)
            }
        }
        _shortcutBindingTexts = State(initialValue: bindingTexts)
        _assignedShortcutIDs = State(initialValue: assignedIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.string("setup.section", defaultValue: "开始使用"))
                        .font(PluginSettingsTheme.Typography.pageTitle)
                    Text(localization.string(
                        "setup.changesSaved",
                        defaultValue: "更改会自动保存。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.rawValue) { candidate in
                    Capsule()
                        .fill(candidate.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .storage:
            storageStep
        case .primaryShortcuts:
            primaryShortcutsStep
        case .sensitiveCopy:
            sensitiveCopyStep
        case .ready:
            readyStep
        }
    }

    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(
                localization.string("setup.collection.title", defaultValue: "准备安全存储"),
                description: storageDescription,
                systemImage: "lock.shield"
            )

            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: storageStatusImage)
                        .font(.title2)
                        .foregroundStyle(storageStatusColor)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(storageStatusTitle)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        if let errorMessage = controller.errorMessage {
                            Text(errorMessage)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if controller.errorMessage != nil {
                        Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                            controller.retryStorageAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .pluginSettingsListRowPadding()

                PluginSettingsListDivider()

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localization.string(
                            "settings.collection.toggleTitle",
                            defaultValue: "收集剪贴板历史"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(collectionDescription)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: Binding(
                        get: { !settings.isPaused && controller.isCollectionOperational },
                        set: { isEnabled in
                            guard controller.isCollectionOperational else { return }
                            settings.setPaused(!isEnabled)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.isCollectionOperational)
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var primaryShortcutsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(
                localization.string("setup.open.title", defaultValue: "设置打开历史快捷键"),
                description: localization.string(
                    "setup.open.description",
                    defaultValue: "设置常用快捷键；再次按下即可关闭历史面板。"
                ),
                systemImage: "keyboard"
            )

            VStack(spacing: 0) {
                actionShortcutRow(
                    settingsContext.actionShortcutItem(
                        actionID: ClipboardHistoryPlugin.ActionID.openHistory
                    )
                )
                PluginSettingsListDivider()
                pluginShortcutRow(
                    settingsContext.shortcutItem(
                        definitionID: ClipboardHistoryPlugin.ShortcutID.pastePlainText
                    ),
                    isOptional: true
                )
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var sensitiveCopyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(
                localization.string("setup.privacy.title", defaultValue: "选择私密复制方式"),
                description: localization.format(
                    "setup.privacy.description",
                    defaultValue: "“立即私密复制”一步完成；“忽略下一次复制”用于之后的右键复制。已设置 %d/2 个可选快捷键。",
                    assignedPrivacyShortcutCount
                ),
                systemImage: "eye.slash"
            )

            VStack(spacing: 0) {
                pluginShortcutRow(
                    settingsContext.shortcutItem(
                        definitionID: ClipboardHistoryPlugin.ShortcutID.privateCopy
                    ),
                    isOptional: true
                )
                PluginSettingsListDivider()
                pluginShortcutRow(
                    settingsContext.shortcutItem(
                        definitionID: ClipboardHistoryPlugin.ShortcutID.ignoreNextCopy
                    ),
                    isOptional: true
                )
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(
                localization.string("setup.ready.title", defaultValue: "剪贴板历史已准备就绪"),
                description: localization.string(
                    "setup.ready.description",
                    defaultValue: "请检查下面的设置。以后可随时重新打开设置指南。"
                ),
                systemImage: "checkmark.circle"
            )

            VStack(spacing: 0) {
                summaryRow(
                    title: localization.string("setup.collection.title", defaultValue: "准备安全存储"),
                    value: storageStatusTitle,
                    isComplete: controller.isLoaded && controller.errorMessage == nil
                )
                PluginSettingsListDivider()
                summaryRow(
                    title: localization.string("settings.collection.toggleTitle", defaultValue: "收集剪贴板历史"),
                    value: settings.isPaused
                        ? localization.string("setup.collection.disabled", defaultValue: "已暂停")
                        : localization.string("setup.collection.enabled", defaultValue: "已开启"),
                    isComplete: !settings.isPaused
                )
                PluginSettingsListDivider()
                summaryRow(
                    title: localization.string("setup.open.title", defaultValue: "设置打开历史快捷键"),
                    value: shortcutBindingTexts[
                        Self.actionShortcutKey(ClipboardHistoryPlugin.ActionID.openHistory)
                    ] ?? "",
                    isComplete: assignedShortcutIDs.contains(
                        Self.actionShortcutKey(ClipboardHistoryPlugin.ActionID.openHistory)
                    )
                )
                PluginSettingsListDivider()
                summaryRow(
                    title: localization.string("setup.privacy.title", defaultValue: "选择私密复制方式"),
                    value: "\(assignedPrivacyShortcutCount) / 2",
                    isComplete: assignedPrivacyShortcutCount > 0
                )
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(localization.string("common.close", defaultValue: "关闭")) {
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            if step != .storage {
                Button(localization.string("setup.back", defaultValue: "返回")) {
                    move(by: -1)
                }
                .buttonStyle(.bordered)
            }

            if step == .ready {
                Button(localization.string("setup.dismiss", defaultValue: "完成")) {
                    settings.completeInitialSetup()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canFinish)
            } else {
                Button(localization.string("setup.next", defaultValue: "继续")) {
                    move(by: 1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canMoveForward)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func stepTitle(
        _ title: String,
        description: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func actionShortcutRow(_ item: PluginSettingsActionShortcutItem?) -> some View {
        if let item {
            let shortcutKey = Self.actionShortcutKey(item.actionID)
            shortcutRow(
                title: item.title,
                description: item.description,
                systemImage: "clipboard",
                bindingText: shortcutBindingTexts[shortcutKey] ?? item.bindingText,
                canAssign: item.canAssign,
                canClear: assignedShortcutIDs.contains(shortcutKey),
                isOptional: false,
                onRecord: { binding in
                    let result = settingsContext.recordActionShortcut(binding, for: item.actionID)
                    if result == .accepted {
                        shortcutBindingTexts[shortcutKey] = ShortcutFormatter.displayString(for: binding)
                        assignedShortcutIDs.insert(shortcutKey)
                    }
                    return result
                },
                onBeginRecording: nil,
                onClear: {
                    settingsContext.clearActionShortcut(for: item.actionID)
                    shortcutBindingTexts[shortcutKey] = ""
                    assignedShortcutIDs.remove(shortcutKey)
                }
            )
        }
    }

    @ViewBuilder
    private func pluginShortcutRow(_ item: ShortcutSettingsItem?, isOptional: Bool) -> some View {
        if let item {
            shortcutRow(
                title: item.settingsControlTitle ?? item.title,
                description: item.description,
                systemImage: item.settingsControlSystemImage ?? "command",
                bindingText: shortcutBindingTexts[item.id] ?? item.bindingText,
                canAssign: true,
                canClear: assignedShortcutIDs.contains(item.id),
                isOptional: isOptional,
                onRecord: { binding in
                    let result = settingsContext.recordShortcut(binding, for: item.id)
                    if result == .accepted {
                        shortcutBindingTexts[item.id] = ShortcutFormatter.displayString(for: binding)
                        assignedShortcutIDs.insert(item.id)
                    }
                    return result
                },
                onBeginRecording: { settingsContext.beginShortcutRecording(for: item.id) },
                onClear: {
                    settingsContext.clearShortcut(for: item.id)
                    shortcutBindingTexts[item.id] = ""
                    assignedShortcutIDs.remove(item.id)
                }
            )
        }
    }

    private func shortcutRow(
        title: String,
        description: String,
        systemImage: String,
        bindingText: String,
        canAssign: Bool,
        canClear: Bool,
        isOptional: Bool,
        onRecord: @escaping (ShortcutBinding) -> PluginShortcutRecordingResult,
        onBeginRecording: (() -> Void)?,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: PluginSystemImage.resolvedName(systemImage))
                .pluginSettingsRowIconStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    if isOptional {
                        Text(localization.string("setup.optional", defaultValue: "可选"))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                }
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PluginShortcutRecorder(
                title: title,
                displayText: bindingText,
                minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth,
                onRecord: onRecord,
                onBeginRecording: onBeginRecording
            )
            .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
            .disabled(!canAssign)
            if canClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localization.string("common.remove", defaultValue: "移除"))
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func summaryRow(title: String, value: String, isComplete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Color.green : Color.secondary)
            Text(title)
                .font(PluginSettingsTheme.Typography.rowTitle)
            Spacer()
            Text(value.isEmpty
                ? localization.string("setup.notAssigned", defaultValue: "未设置")
                : value
            )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .pluginSettingsListRowPadding()
    }

    private var assignedPrivacyShortcutCount: Int {
        [
            ClipboardHistoryPlugin.ShortcutID.privateCopy,
            ClipboardHistoryPlugin.ShortcutID.ignoreNextCopy,
        ]
        .map { "\(settingsContext.pluginID).shortcut.\($0)" }
        .filter { assignedShortcutIDs.contains($0) }
        .count
    }

    private var storageDescription: String {
        if controller.errorMessage != nil {
            return localization.string(
                "setup.collection.errorDescription",
                defaultValue: "需要先解决加密存储问题，才能开始收集。"
            )
        }
        if !controller.isLoaded {
            return localization.string(
                "setup.collection.loadingDescription",
                defaultValue: "正在准备加密存储。准备完成后即可开始使用。"
            )
        }
        return localization.string(
            "setup.collection.readyDescription",
            defaultValue: "安全存储已就绪。钥匙串只保存本机密钥；不需要 iCloud 钥匙串。"
        )
    }

    private var collectionDescription: String {
        settings.isPaused
            ? localization.string(
                "setup.collection.pausedDescription",
                defaultValue: "当前已暂停；可在下方开启“收集剪贴板历史”。"
            )
            : localization.string(
                "settings.collection.activeDescription",
                defaultValue: "收集已开启。历史保存在本机加密数据库中，钥匙串只保存加密密钥。"
            )
    }

    private var storageStatusTitle: String {
        if controller.errorMessage != nil {
            return localization.string("settings.storage.status.attention", defaultValue: "需要处理")
        }
        if controller.isLoaded {
            return localization.string("settings.storage.status.ready", defaultValue: "已就绪")
        }
        return localization.string("settings.storage.status.preparing", defaultValue: "准备中")
    }

    private var storageStatusImage: String {
        if controller.errorMessage != nil { return "exclamationmark.triangle.fill" }
        return controller.isLoaded ? "checkmark.shield.fill" : "hourglass"
    }

    private var storageStatusColor: Color {
        if controller.errorMessage != nil { return .orange }
        return controller.isLoaded ? .green : .secondary
    }

    private var canMoveForward: Bool {
        step != .storage || (controller.isLoaded && controller.errorMessage == nil)
    }

    private var canFinish: Bool {
        controller.isLoaded && controller.errorMessage == nil
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        step = next
    }

    private static func actionShortcutKey(_ actionID: String) -> String {
        "action.\(actionID)"
    }
}
