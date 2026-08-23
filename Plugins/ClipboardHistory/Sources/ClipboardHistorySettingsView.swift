import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ClipboardHistorySettingsView: View {
    @ObservedObject var controller: ClipboardHistoryController
    @ObservedObject private var settings: ClipboardHistorySettingsStore
    private let localization: PluginLocalization
    private let privacyShortcutItems: [ShortcutSettingsItem]
    @State private var clearRequest: ClipboardHistorySettingsClearRequest?

    init(
        controller: ClipboardHistoryController,
        localization: PluginLocalization,
        privacyShortcutItems: [ShortcutSettingsItem] = []
    ) {
        self.controller = controller
        self.localization = localization
        self.privacyShortcutItems = privacyShortcutItems
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if !settings.hasCompletedInitialSetup {
                initialSetupSection
            }
            collectionSection
            retentionSection
            exclusionsSection
            dataSection
        }
        .alert(item: $clearRequest) { request in
            switch request {
            case .unpinned:
                Alert(
                    title: Text(localization.string("clear.unpinned.title", defaultValue: "清除未固定的历史记录？")),
                    message: Text(localization.string("clear.unpinned.message", defaultValue: "固定片段会保留。此操作无法撤销。")),
                    primaryButton: .destructive(Text(localization.string("common.clear", defaultValue: "清除"))) {
                        Task { await controller.clearUnpinnedHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .all:
                Alert(
                    title: Text(localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？")),
                    message: Text(localization.string("clear.all.message", defaultValue: "所有历史记录和固定片段都会被永久删除。")),
                    primaryButton: .destructive(Text(localization.string("common.clearAll", defaultValue: "全部清除"))) {
                        Task { await controller.clearAllHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            }
        }
    }

    private var initialSetupSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(
                    localization.string("setup.section", defaultValue: "开始使用"),
                    systemImage: "checklist"
                )
                Spacer()
                Button(localization.string("setup.dismiss", defaultValue: "完成")) {
                    settings.completeInitialSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            VStack(spacing: 0) {
                setupRow(
                    number: 1,
                    title: localization.string("setup.collection.title", defaultValue: "确认收集状态"),
                    description: setupCollectionDescription,
                    tone: setupCollectionTone
                )
                PluginSettingsListDivider()
                setupRow(
                    number: 2,
                    title: localization.string("setup.open.title", defaultValue: "设置打开历史快捷键"),
                    description: localization.string(
                        "setup.open.description",
                        defaultValue: "在下方“主要快捷键”中设置常用快捷键；再次按下即可关闭历史面板。"
                    ),
                    tone: .neutral
                )
                PluginSettingsListDivider()
                setupRow(
                    number: 3,
                    title: localization.string("setup.privacy.title", defaultValue: "选择私密复制方式"),
                    description: localization.format(
                        "setup.privacy.description",
                        defaultValue: "“立即私密复制”一步完成；“忽略下一次复制”用于之后的右键复制。已设置 %d/2 个可选快捷键。",
                        assignedPrivacyShortcutCount
                    ),
                    tone: assignedPrivacyShortcutCount > 0 ? .positive : .neutral
                )
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.collection.section", defaultValue: "收集"), systemImage: "clipboard")
            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string(
                            "settings.collection.toggleTitle",
                            defaultValue: "收集剪贴板历史"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(collectionDescription)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(
                                controller.errorMessage == nil ? Color.secondary : Color.red
                            )

                        if controller.errorMessage != nil {
                            Button(localization.string(
                                "settings.collection.resetAction",
                                defaultValue: "重置加密历史…"
                            )) {
                                clearRequest = .all
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(localization.string("settings.collection.toggle", defaultValue: "收集剪贴板历史"), isOn: Binding(
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

                PluginSettingsListDivider()

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string("settings.privacy.title", defaultValue: "隐私边界"))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.privacy.description",
                            defaultValue: "历史内容保存在本机加密文件中，钥匙串只保存密钥；文件仅保存路径引用。"
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "lock.shield")
                        .pluginSettingsRowIconStyle(.green)
                }
                .pluginSettingsListRowPadding()
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var collectionDescription: String {
        if let errorMessage = controller.errorMessage {
            return errorMessage
        }
        if !controller.isLoaded {
            return localization.string(
                "settings.collection.loadingDescription",
                defaultValue: "正在准备本机加密存储…"
            )
        }
        if controller.isClearingHistory {
            return localization.string(
                "settings.collection.clearingDescription",
                defaultValue: "正在安全清除加密历史…"
            )
        }
        if settings.isPaused {
            return localization.string(
                "settings.collection.pausedDescription",
                defaultValue: "收集已暂停；现有加密历史仍保留在本机。"
            )
        }
        return localization.string(
            "settings.collection.activeDescription",
            defaultValue: "收集已开启。历史保存在本机加密文件中，钥匙串只保存加密密钥。"
        )
    }

    private var assignedPrivacyShortcutCount: Int {
        privacyShortcutItems.filter(\.canClear).count
    }

    private var setupCollectionDescription: String {
        if controller.errorMessage != nil {
            return localization.string(
                "setup.collection.errorDescription",
                defaultValue: "需要先解决下方的加密存储问题，才能开始收集。"
            )
        }
        if !controller.isLoaded {
            return localization.string(
                "setup.collection.loadingDescription",
                defaultValue: "正在准备加密存储。准备完成后即可开始使用。"
            )
        }
        if settings.isPaused {
            return localization.string(
                "setup.collection.pausedDescription",
                defaultValue: "当前已暂停；可在下方开启“收集剪贴板历史”。"
            )
        }
        return localization.string(
            "setup.collection.readyDescription",
            defaultValue: "已就绪。历史在本机加密，钥匙串仅保存密钥。"
        )
    }

    private var setupCollectionTone: PluginStatusTone {
        if controller.errorMessage != nil {
            return .caution
        }
        if controller.isLoaded, !settings.isPaused {
            return .positive
        }
        return .neutral
    }

    private func setupRow(
        number: Int,
        title: String,
        description: String,
        tone: PluginStatusTone
    ) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text("\(number)")
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(statusColor(tone))
                .frame(width: 22, height: 22)
                .background(statusColor(tone).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(tone == .caution ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pluginSettingsListRowPadding()
    }

    private func statusColor(_ tone: PluginStatusTone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .positive: .green
        case .caution: .orange
        }
    }

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.retention.section", defaultValue: "保留规则"), systemImage: "clock.arrow.circlepath")
            VStack(spacing: 0) {
                settingPickerRow(
                    title: localization.string("settings.retention.maximum.title", defaultValue: "最多保留"),
                    description: localization.string("settings.retention.maximum.description", defaultValue: "固定片段也计入总数。"),
                    selection: $settings.maximumItemCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedItemCounts, id: \.self) { count in
                        Text(
                            count == ClipboardHistorySettings.noItemCountLimit
                                ? localization.string(
                                    "settings.retention.itemCount.noLimit",
                                    defaultValue: "不限制条数"
                                )
                                : localization.format(
                                    "settings.retention.itemCount",
                                    defaultValue: "%d 条",
                                    count
                                )
                        )
                        .tag(count)
                    }
                }
                PluginSettingsListDivider()
                settingPickerRow(
                    title: localization.string("settings.retention.expiration.title", defaultValue: "自动过期"),
                    description: localization.string("settings.retention.expiration.description", defaultValue: "固定片段不会按时间过期。"),
                    selection: $settings.expiration
                ) {
                    ForEach(ClipboardHistoryExpiration.allCases) { expiration in
                        Text(expirationTitle(expiration)).tag(expiration)
                    }
                }
                PluginSettingsListDivider()
                settingPickerRow(
                    title: localization.string("settings.retention.itemLimit.title", defaultValue: "单条内容上限"),
                    description: localization.string(
                        "settings.retention.itemLimit.description",
                        defaultValue: "文本、图片或其他内嵌内容超过上限时不会保存；文件仅保存引用。"
                    ),
                    selection: $settings.maximumItemByteCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedItemByteCounts, id: \.self) { count in
                        Text(byteCountTitle(count)).tag(count)
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(localization.string("settings.exclusions.section", defaultValue: "排除的应用"), systemImage: "app.badge.checkmark")
                Spacer()
                Button {
                    chooseExcludedApplications()
                } label: {
                    Label(localization.string("common.add", defaultValue: "添加"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(spacing: 0) {
                if settings.excludedApplications.isEmpty {
                    Text(localization.string("settings.exclusions.empty", defaultValue: "未排除任何应用"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsListRowPadding()
                } else {
                    ForEach(Array(settings.excludedApplications.enumerated()), id: \.element.id) { index, app in
                        let localizedAppName = displayName(for: app)
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            Image(systemName: "app")
                                .pluginSettingsRowIconStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                                Text(localizedAppName)
                                    .font(PluginSettingsTheme.Typography.rowTitle)
                                Text(app.bundleIdentifier)
                                    .font(PluginSettingsTheme.Typography.rowDescription.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                settings.removeExcludedApplication(bundleIdentifier: app.bundleIdentifier)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(localization.string("common.remove", defaultValue: "移除"))
                            .accessibilityLabel(localization.format(
                                "settings.exclusions.removeAccessibility",
                                defaultValue: "移除 %@",
                                localizedAppName
                            ))
                        }
                        .pluginSettingsListRowPadding(interactive: true)
                        if index < settings.excludedApplications.count - 1 {
                            PluginSettingsListDivider()
                        }
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)

            Text(localization.string(
                "settings.exclusions.footnote",
                defaultValue: "排除依据是复制发生时观察到的前台应用，不能替代密码管理器或安全输入保护。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.data.section", defaultValue: "本机数据"), systemImage: "externaldrive")
            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.format(
                            "settings.data.savedCount",
                            defaultValue: "已保存 %d 条",
                            controller.items.count
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.format(
                            "settings.data.pinnedCount",
                            defaultValue: "其中 %d 条已固定。过期内容会从加密存储中删除。",
                            controller.pinnedItems.count
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(localization.string("settings.data.clearUnpinned", defaultValue: "清除未固定记录"), role: .destructive) {
                        clearRequest = .unpinned
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.recentItems.isEmpty || controller.isClearingHistory)
                    Button(localization.string("common.clearAll", defaultValue: "全部清除"), role: .destructive) {
                        clearRequest = .all
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        (controller.items.isEmpty && controller.errorMessage == nil)
                            || controller.isClearingHistory
                    )
                }
                .pluginSettingsListRowPadding(interactive: true)

                if let errorMessage = controller.errorMessage {
                    PluginSettingsListDivider()
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsListRowPadding()
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func displayName(for application: ClipboardExcludedApplication) -> String {
        let installedLocalizedName: String? = if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        ),
           let applicationBundle = Bundle(url: applicationURL),
           let localizedName = (applicationBundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
               ?? applicationBundle.object(forInfoDictionaryKey: "CFBundleName")) as? String,
           !localizedName.isEmpty {
            localizedName
        } else {
            nil
        }
        return ClipboardExcludedApplicationDisplayName.resolve(
            application: application,
            installedLocalizedName: installedLocalizedName
        ) { key in
            switch key {
            case "excludedApplication.passwords":
                localization.string("excludedApplication.passwords", defaultValue: "密码")
            case "excludedApplication.keychainAccess":
                localization.string("excludedApplication.keychainAccess", defaultValue: "钥匙串访问")
            default:
                nil
            }
        }
    }

    private func settingPickerRow<Selection: Hashable, Content: View>(
        title: String,
        description: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func chooseExcludedApplications() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }

        let applications = panel.urls.compactMap { url -> ClipboardExcludedApplication? in
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  !identifier.isEmpty else {
                return nil
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return ClipboardExcludedApplication(bundleIdentifier: identifier, name: name)
        }
        settings.addExcludedApplications(applications)
    }

    private func expirationTitle(_ expiration: ClipboardHistoryExpiration) -> String {
        switch expiration {
        case .never: localization.string("settings.retention.expiration.never", defaultValue: "永不")
        case .oneDay: localization.string("settings.retention.expiration.oneDay", defaultValue: "1 天")
        case .sevenDays: localization.string("settings.retention.expiration.sevenDays", defaultValue: "7 天")
        case .thirtyDays: localization.string("settings.retention.expiration.thirtyDays", defaultValue: "30 天")
        case .ninetyDays: localization.string("settings.retention.expiration.ninetyDays", defaultValue: "90 天")
        }
    }

    private func byteCountTitle(_ byteCount: Int) -> String {
        byteCount >= 1_024 * 1_024
            ? localization.format(
                "settings.retention.byteCount.megabytes",
                defaultValue: "%d MB",
                byteCount / (1_024 * 1_024)
            )
            : localization.format(
                "settings.retention.byteCount.kilobytes",
                defaultValue: "%d KB",
                byteCount / 1_024
            )
    }
}

private enum ClipboardHistorySettingsClearRequest: String, Identifiable {
    case unpinned
    case all

    var id: String { rawValue }
}
