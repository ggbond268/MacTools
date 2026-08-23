import MacToolsPluginKit
import SwiftUI

enum ClipboardHistorySetupDestination: String, Identifiable {
    case guide

    var id: String { rawValue }
}

enum ClipboardHistorySetupStep: Int, CaseIterable, Identifiable {
    case storage
    case collection
    case primaryShortcuts
    case sensitiveCopy

    var id: Int { rawValue }
}

struct ClipboardHistorySetupProgress: Equatable {
    let storageReady: Bool
    let collectionEnabled: Bool
    let primaryShortcutAssigned: Bool
    let privacyShortcutAssigned: Bool
    let hasRevealedShortcutSections: Bool

    var completedRequiredStepCount: Int {
        [storageReady, collectionEnabled].filter { $0 }.count
    }

    var canFinish: Bool {
        storageReady && collectionEnabled
    }

    func isConfigured(_ step: ClipboardHistorySetupStep) -> Bool {
        switch step {
        case .storage:
            storageReady
        case .collection:
            collectionEnabled
        case .primaryShortcuts:
            primaryShortcutAssigned
        case .sensitiveCopy:
            privacyShortcutAssigned
        }
    }

    func canReveal(_ step: ClipboardHistorySetupStep) -> Bool {
        switch step {
        case .storage:
            true
        case .collection:
            storageReady
        case .primaryShortcuts, .sensitiveCopy:
            hasRevealedShortcutSections
        }
    }
}

@MainActor
struct ClipboardHistorySetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller: ClipboardHistoryController
    @ObservedObject private var settings: ClipboardHistorySettingsStore
    private let localization: PluginLocalization
    private let settingsContext: PluginSettingsContext
    @State private var expandedStep: ClipboardHistorySetupStep?
    @State private var shortcutBindingTexts: [String: String]
    @State private var assignedShortcutIDs: Set<String>
    @State private var hasRevealedShortcutSections: Bool

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

        let primaryAssigned = assignedIDs.contains(Self.openHistoryShortcutKey)
        let completedPreviously = controller.settings.hasCompletedInitialSetup
        let collectionEnabled = !controller.settings.isPaused && controller.isCollectionOperational
        let storageReady = controller.isLoaded && controller.errorMessage == nil
        let initialProgress = ClipboardHistorySetupProgress(
            storageReady: storageReady,
            collectionEnabled: collectionEnabled,
            primaryShortcutAssigned: primaryAssigned,
            privacyShortcutAssigned: Self.privacyShortcutKeys.contains { assignedIDs.contains($0) },
            hasRevealedShortcutSections: collectionEnabled || completedPreviously
        )

        _shortcutBindingTexts = State(initialValue: bindingTexts)
        _assignedShortcutIDs = State(initialValue: assignedIDs)
        _hasRevealedShortcutSections = State(
            initialValue: collectionEnabled || completedPreviously
        )
        _expandedStep = State(
            initialValue: completedPreviously || initialProgress.canFinish
                ? nil
                : (storageReady ? .collection : .storage)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ClipboardHistorySetupStep.allCases) { step in
                        if progress.canReveal(step) || settings.hasCompletedInitialSetup {
                            setupSection(for: step)
                                .id(step)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 620)
        .onChange(of: collectionEnabled) { _, isEnabled in
            if isEnabled {
                hasRevealedShortcutSections = true
            }
        }
    }

    private var header: some View {
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
            Text(progress.canFinish
                ? localization.string("setup.readyStatus", defaultValue: "可以开始使用")
                : localization.format(
                    "setup.requiredProgress",
                    defaultValue: "已完成 %d/%d 个必需步骤",
                    progress.completedRequiredStepCount,
                    2
                )
            )
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(progress.canFinish ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private func setupSection(for step: ClipboardHistorySetupStep) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedStep = expandedStep == step ? nil : step
                }
            } label: {
                HStack(spacing: 12) {
                    stepStatusIcon(for: step)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(stepTitle(for: step))
                                .font(PluginSettingsTheme.Typography.rowTitle)
                                .foregroundStyle(.primary)
                            if step == .collection {
                                statusBadge(
                                    localization.string("setup.required", defaultValue: "必需"),
                                    color: .orange
                                )
                            } else if step == .primaryShortcuts {
                                statusBadge(
                                    localization.string("setup.recommended", defaultValue: "推荐"),
                                    color: .secondary
                                )
                            } else if step == .sensitiveCopy {
                                statusBadge(
                                    localization.string("setup.optional", defaultValue: "可选"),
                                    color: .secondary
                                )
                            }
                        }
                        Text(stepSummary(for: step))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expandedStep == step ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .contentShape(Rectangle())
                .pluginSettingsListRowPadding(interactive: true)
            }
            .buttonStyle(.plain)

            if expandedStep == step {
                PluginSettingsListDivider()
                stepContent(for: step)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .pluginSettingsCardBackground(.standard)
    }

    @ViewBuilder
    private func stepContent(for step: ClipboardHistorySetupStep) -> some View {
        switch step {
        case .storage:
            storageContent
        case .collection:
            collectionContent
        case .primaryShortcuts:
            primaryShortcutsContent
        case .sensitiveCopy:
            sensitiveCopyContent
        }
    }

    private var storageContent: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: 4) {
                Text(storageDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(controller.errorMessage == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    private var collectionContent: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string(
                "setup.collection.actionDescription",
                defaultValue: "开启后，新复制的内容会保存在本机加密历史中。你以后可以随时暂停收集。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { collectionEnabled },
                set: { isEnabled in
                    guard controller.isCollectionOperational else { return }
                    settings.setPaused(!isEnabled)
                    if isEnabled {
                        hasRevealedShortcutSections = true
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!controller.isCollectionOperational)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var primaryShortcutsContent: some View {
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
    }

    private var sensitiveCopyContent: some View {
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
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(localization.string("common.close", defaultValue: "关闭")) {
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(localization.string("setup.dismiss", defaultValue: "完成")) {
                if progress.canFinish {
                    settings.completeInitialSetup()
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!progress.canFinish && !settings.hasCompletedInitialSetup)
        }
        .controlSize(.regular)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
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
                        statusBadge(
                            localization.string("setup.optional", defaultValue: "可选"),
                            color: .secondary
                        )
                    }
                }
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PluginSettingsShortcutRecorderControl(
                title: title,
                displayText: bindingText,
                canAssign: canAssign,
                canClear: canClear,
                clearTitle: localization.string("common.remove", defaultValue: "移除"),
                onRecord: onRecord,
                onBeginRecording: onBeginRecording,
                onClear: onClear
            )
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func stepStatusIcon(for step: ClipboardHistorySetupStep) -> some View {
        let isConfigured = progress.isConfigured(step)
        let hasError = step == .storage && controller.errorMessage != nil
        let imageName: String
        let color: Color

        if isConfigured {
            imageName = "checkmark.circle.fill"
            color = .green
        } else if hasError || (step == .collection && storageReady) {
            imageName = "exclamationmark.circle.fill"
            color = .orange
        } else {
            imageName = "circle"
            color = .secondary
        }

        return Image(systemName: imageName)
            .font(.title3)
            .foregroundStyle(color)
            .frame(width: 26)
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func stepTitle(for step: ClipboardHistorySetupStep) -> String {
        switch step {
        case .storage:
            localization.string("setup.storage.title", defaultValue: "准备安全存储")
        case .collection:
            localization.string("settings.collection.toggleTitle", defaultValue: "收集剪贴板历史")
        case .primaryShortcuts:
            localization.string("setup.open.title", defaultValue: "设置主要快捷键")
        case .sensitiveCopy:
            localization.string("setup.privacy.title", defaultValue: "保护敏感复制内容")
        }
    }

    private func stepSummary(for step: ClipboardHistorySetupStep) -> String {
        switch step {
        case .storage:
            return storageStatusTitle
        case .collection:
            return collectionEnabled
                ? localization.string("setup.collection.enabled", defaultValue: "已开启")
                : localization.string("setup.collection.disabled", defaultValue: "已暂停")
        case .primaryShortcuts:
            let binding = shortcutBindingTexts[Self.openHistoryShortcutKey] ?? ""
            return binding.isEmpty
                ? localization.string("setup.notConfigured", defaultValue: "未配置")
                : binding
        case .sensitiveCopy:
            return localization.format(
                "setup.privacy.progress",
                defaultValue: "已设置 %d/2 个隐私快捷键",
                assignedPrivacyShortcutCount
            )
        }
    }

    private var progress: ClipboardHistorySetupProgress {
        ClipboardHistorySetupProgress(
            storageReady: storageReady,
            collectionEnabled: collectionEnabled,
            primaryShortcutAssigned: assignedShortcutIDs.contains(Self.openHistoryShortcutKey),
            privacyShortcutAssigned: assignedPrivacyShortcutCount > 0,
            hasRevealedShortcutSections: hasRevealedShortcutSections
        )
    }

    private var storageReady: Bool {
        controller.isLoaded && controller.errorMessage == nil
    }

    private var collectionEnabled: Bool {
        !settings.isPaused && controller.isCollectionOperational
    }

    private var assignedPrivacyShortcutCount: Int {
        Self.privacyShortcutKeys.filter { assignedShortcutIDs.contains($0) }.count
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

    private var storageStatusTitle: String {
        if controller.errorMessage != nil {
            return localization.string("settings.storage.status.attention", defaultValue: "需要处理")
        }
        if controller.isLoaded {
            return localization.string("settings.storage.status.ready", defaultValue: "已就绪")
        }
        return localization.string("settings.storage.status.preparing", defaultValue: "准备中")
    }

    private static let openHistoryShortcutKey = actionShortcutKey(
        ClipboardHistoryPlugin.ActionID.openHistory
    )

    private static let privacyShortcutKeys: [String] = [
        ClipboardHistoryPlugin.ShortcutID.privateCopy,
        ClipboardHistoryPlugin.ShortcutID.ignoreNextCopy,
    ].map { "\(ClipboardHistoryPlugin.pluginID).shortcut.\($0)" }

    private static func actionShortcutKey(_ actionID: String) -> String {
        "action.\(actionID)"
    }
}
