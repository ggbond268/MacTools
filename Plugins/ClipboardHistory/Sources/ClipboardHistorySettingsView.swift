import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardHistorySettingsContentSection: Hashable {
    case essentials
    case retention
    case exclusions
    case data
}

@MainActor
struct ClipboardHistorySettingsView: View {
    @ObservedObject var controller: ClipboardHistoryController
    @ObservedObject private var settings: ClipboardHistorySettingsStore
    private let localization: PluginLocalization
    private let settingsContext: PluginSettingsContext?
    private let contentSections: Set<ClipboardHistorySettingsContentSection>
    @State private var clearRequest: ClipboardHistorySettingsClearRequest?
    @State private var setupDestination: ClipboardHistorySetupDestination?

    init(
        controller: ClipboardHistoryController,
        localization: PluginLocalization,
        settingsContext: PluginSettingsContext? = nil,
        contentSections: Set<ClipboardHistorySettingsContentSection> = [
            .essentials,
            .retention,
            .exclusions,
            .data,
        ]
    ) {
        self.controller = controller
        self.localization = localization
        self.settingsContext = settingsContext
        self.contentSections = contentSections
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if contentSections.contains(.essentials) {
                collectionSection
            }
            if contentSections.contains(.retention) {
                retentionSection
            }
            if contentSections.contains(.exclusions) {
                exclusionsSection
            }
            if contentSections.contains(.data) {
                dataSection
            }
        }
        .onAppear {
            guard contentSections.contains(.essentials),
                  settingsContext != nil,
                  settings.shouldAutomaticallyPresentInitialSetup()
            else {
                return
            }
            setupDestination = .guide
        }
        .sheet(item: $setupDestination) { _ in
            if let settingsContext {
                ClipboardHistorySetupSheet(
                    controller: controller,
                    localization: localization,
                    settingsContext: settingsContext
                )
            }
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
            case .resetUnreadable:
                Alert(
                    title: Text(localization.string(
                        "settings.storage.reset.title",
                        defaultValue: "删除无法读取的历史记录？"
                    )),
                    message: Text(localization.string(
                        "settings.storage.reset.message",
                        defaultValue: "这会删除加密数据库及其钥匙串密钥。现有剪贴板历史将无法恢复。"
                    )),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.storage.reset.confirm",
                        defaultValue: "删除并重新开始"
                    ))) {
                        Task { await controller.resetUnreadablePersistentHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            }
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(
                    localization.string("settings.collection.section", defaultValue: "收集与安全"),
                    systemImage: "clipboard"
                )
                Spacer()
                Button {
                    setupDestination = .guide
                } label: {
                    Label(
                        settings.hasCompletedInitialSetup
                            ? localization.string("setup.show", defaultValue: "设置指南")
                            : localization.string("setup.continue", defaultValue: "继续设置"),
                        systemImage: "questionmark.circle"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(settingsContext == nil)
            }
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
                        Text(localization.string(
                            "settings.storage.encrypted.title",
                            defaultValue: "本机加密存储"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.storage.encrypted.description",
                            defaultValue: "历史保存在本机加密数据库中，钥匙串只保存这台 Mac 的加密密钥；不需要 iCloud 钥匙串。"
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(encryptedStorageStatusTitle)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(encryptedStorageStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(encryptedStorageStatusColor.opacity(0.12), in: Capsule())
                }
                .pluginSettingsListRowPadding()

                PluginSettingsListDivider()

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string("settings.privacy.title", defaultValue: "隐私边界"))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(privacyDescription)
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
            defaultValue: "收集已开启。历史保存在本机加密数据库中，钥匙串只保存加密密钥。"
        )
    }

    private var encryptedStorageStatusTitle: String {
        if controller.errorMessage != nil {
            return localization.string("settings.storage.status.attention", defaultValue: "需要处理")
        }
        if controller.isLoaded {
            return localization.string("settings.storage.status.ready", defaultValue: "已就绪")
        }
        return localization.string("settings.storage.status.preparing", defaultValue: "准备中")
    }

    private var encryptedStorageStatusColor: Color {
        if controller.errorMessage != nil {
            return .orange
        }
        return controller.isLoaded ? .green : .secondary
    }

    private var privacyDescription: String {
        localization.string(
            "settings.privacy.description",
            defaultValue: "暂时无法访问钥匙串不会删除历史；删除加密密钥会使现有历史永久无法读取。文件仅保存路径引用。"
        )
    }

    private var storageRecoveryDescription: String? {
        switch controller.storageError {
        case .keychain:
            localization.string(
                "settings.storage.recovery.keychain",
                defaultValue: "如 macOS 显示提示，请允许 MacTools 访问本机钥匙串，然后重试。现有历史记录尚未删除。"
            )
        case .missingEncryptionKey, .invalidEncryptionKey:
            localization.string(
                "settings.storage.recovery.missingKey",
                defaultValue: "现有数据库只有使用原来的加密密钥才能读取。请先尝试恢复该密钥；确认无法恢复后，才能删除无法读取的历史并重新开始。"
            )
        case .invalidEnvelope, .authenticationFailed, .historyTooLarge:
            localization.string(
                "settings.storage.recovery.unreadable",
                defaultValue: "原始加密数据已保留。请先重试；确认不再需要恢复时再删除它。"
            )
        case .insufficientDiskSpace, .unavailableStorage:
            localization.string(
                "settings.storage.recovery.unavailable",
                defaultValue: "解决本机存储问题后重试。问题解决前，剪贴板历史不会继续收集。"
            )
        case nil:
            nil
        }
    }

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.retention.section", defaultValue: "保留规则"), systemImage: "clock.arrow.circlepath")
            VStack(spacing: 0) {
                settingPickerRow(
                    title: localization.string("settings.retention.maximum.title", defaultValue: "最多保留"),
                    description: localization.string(
                        "settings.retention.maximum.description",
                        defaultValue: "达到条数上限时，会自动移除最早的未固定项目；固定项目不会自动删除。"
                    ),
                    selection: $settings.maximumItemCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedItemCounts, id: \.self) { count in
                        Text(
                            count == ClipboardHistorySettings.maximumSupportedItemCount
                                ? localization.string(
                                    "settings.retention.itemCount.noLimit",
                                    defaultValue: "10,000 条"
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
                    title: localization.string(
                        "settings.retention.storageLimit.title",
                        defaultValue: "历史容量"
                    ),
                    description: localization.string(
                        "settings.retention.storageLimit.description",
                        defaultValue: "达到容量上限时移除最早的未固定项目。实际保存仍受可用磁盘空间限制。"
                    ),
                    selection: $settings.maximumTotalPayloadByteCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedTotalPayloadByteCounts, id: \.self) { count in
                        Text(byteCountTitle(count)).tag(count)
                    }
                }
                PluginSettingsListDivider()
                settingPickerRow(
                    title: localization.string("settings.retention.expiration.title", defaultValue: "自动过期"),
                    description: localization.string(
                        "settings.retention.expiration.description",
                        defaultValue: "“永不”仅关闭按时间过期；容量规则仍会移除最早的未固定项目。"
                    ),
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
        let historyUsage = controller.usage
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.data.section", defaultValue: "本机数据"), systemImage: "externaldrive")
            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.format(
                            "settings.data.savedCount",
                            defaultValue: "%d / %d 条 · %@ / %@",
                            historyUsage.itemCount,
                            settings.maximumItemCount,
                            byteCountTitle(historyUsage.payloadByteCount),
                            byteCountTitle(settings.maximumTotalPayloadByteCount)
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.format(
                            "settings.data.pinnedCount",
                            defaultValue: "其中 %d 条已固定；固定项目不会自动删除。",
                            historyUsage.pinnedItemCount
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
                    .disabled(
                        controller.errorMessage != nil
                            || controller.recentItems.isEmpty
                            || controller.isClearingHistory
                    )
                    Button(localization.string("common.clearAll", defaultValue: "全部清除"), role: .destructive) {
                        clearRequest = .all
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        controller.errorMessage != nil
                            || controller.items.isEmpty
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

                    if let recoveryDescription = storageRecoveryDescription {
                        Text(recoveryDescription)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pluginSettingsListRowPadding()
                    }

                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                            controller.retryStorageAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if controller.canResetUnreadablePersistentHistory {
                            Button(localization.string(
                                "settings.storage.resetUnreadable",
                                defaultValue: "删除无法读取的历史…"
                            ), role: .destructive) {
                                clearRequest = .resetUnreadable
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Spacer()
                    }
                    .pluginSettingsListRowPadding(interactive: true)
                }

                if controller.isCaptureBlockedByPinnedItems {
                    PluginSettingsListDivider()
                    Label(
                        localization.string(
                            "settings.data.pinnedCapacityWarning",
                            defaultValue: "固定项目已占满历史容量。请取消固定或删除项目后再保存新的历史记录。"
                        ),
                        systemImage: "pin.slash"
                    )
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
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
        PluginPresentationSafety.prepareForWindowOrdering()
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
        if byteCount >= 1_024 * 1_024 * 1_024 {
            return localization.format(
                "settings.retention.byteCount.gigabytes",
                defaultValue: "%d GB",
                byteCount / (1_024 * 1_024 * 1_024)
            )
        }
        return byteCount >= 1_024 * 1_024
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
    case resetUnreadable

    var id: String { rawValue }
}
