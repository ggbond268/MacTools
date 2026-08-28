import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardHistorySettingsContentSection: Hashable {
    case essentials
    case queue
    case saved
    case snippets
    case advanced
    case additionalShortcuts
    case retention
    case exclusions
    case data
}

@MainActor
struct ClipboardHistorySettingsView: View {
    @ObservedObject var controller: ClipboardHistoryController
    @ObservedObject var savedLibraryController: ClipboardSavedLibraryController
    @ObservedObject private var settings: ClipboardHistorySettingsStore
    private let localization: PluginLocalization
    private let settingsContext: PluginSettingsContext?
    private let contentSections: Set<ClipboardHistorySettingsContentSection>
    private let onManageSnippets: (() -> Void)?
    @State private var clearRequest: ClipboardHistorySettingsClearRequest?
    @State private var setupDestination: ClipboardHistorySetupDestination?
    @State private var expandedAdvancedSections: Set<ClipboardHistorySettingsContentSection> = []
    @State private var showsPrivacyDetails = false
    @State private var isWindowShortcutsExpanded = false
    @State private var isCollectionShortcutsExpanded = false
    @State private var isMaintenanceExpanded = false
    @State private var isSnippetAdvancedExpanded = false

    init(
        controller: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController,
        localization: PluginLocalization,
        settingsContext: PluginSettingsContext? = nil,
        contentSections: Set<ClipboardHistorySettingsContentSection> = [
            .essentials,
            .queue,
            .snippets,
            .advanced,
            .additionalShortcuts,
            .retention,
            .exclusions,
            .data,
        ],
        onManageSnippets: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.savedLibraryController = savedLibraryController
        self.localization = localization
        self.settingsContext = settingsContext
        self.contentSections = contentSections
        self.onManageSnippets = onManageSnippets
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if contentSections.contains(.essentials) {
                essentialsSection
            }
            if contentSections.contains(.queue) {
                sequentialPasteSection
            }
            if contentSections.contains(.saved) {
                savedLibrarySection
            }
            if contentSections.contains(.snippets) {
                snippetsSection
            }
            if contentSections.contains(.advanced) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Text(localization.string("settings.advanced.title", defaultValue: "Advanced Settings"))
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(.secondary)
                    Divider().frame(maxWidth: .infinity, maxHeight: 1)
                }
                .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
            }
            if contentSections.contains(.additionalShortcuts) {
                additionalShortcutsSection
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
            case .all:
                Alert(
                    title: Text(localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？")),
                    message: Text(localization.string(
                        "clear.all.message",
                        defaultValue: "Clears History. Saved clips and snippets are kept. This cannot be undone."
                    )),
                    primaryButton: .destructive(Text(localization.string("settings.data.clearHistory", defaultValue: "Clear History"))) {
                        Task { await controller.clearAllHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .savedClips:
                Alert(
                    title: Text(localization.string(
                        "settings.saved.clear.title",
                        defaultValue: "Clear Saved Clips?"
                    )),
                    message: Text(localization.string(
                        "settings.saved.clear.message",
                        defaultValue: "Removes Saved status from clips in History and permanently deletes Saved-only clips. History and snippets are kept. This cannot be undone."
                    )),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.saved.clear.confirm",
                        defaultValue: "Clear Saved Clips"
                    ))) {
                        Task { _ = await controller.clearAllSavedItems() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .snippets:
                Alert(
                    title: Text(localization.string(
                        "settings.snippets.clear.title",
                        defaultValue: "Delete All Snippets?"
                    )),
                    message: Text(localization.string(
                        "settings.snippets.clear.message",
                        defaultValue: "Permanently deletes all snippets and their keywords. History and Saved clips are kept. This cannot be undone."
                    )),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.snippets.clear.confirm",
                        defaultValue: "Delete Snippets"
                    ))) {
                        Task { _ = await savedLibraryController.clearAll() }
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
                        defaultValue: "This deletes the encrypted Clipboard database and its Keychain key. History and Saved items cannot be recovered."
                    )),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.storage.reset.confirm",
                        defaultValue: "删除并重新开始"
                    ))) {
                        Task {
                            if await controller.resetUnreadablePersistentHistory() {
                                savedLibraryController.reloadAfterExternalDatabaseReset()
                            }
                        }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            }
        }
    }

    private var essentialsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            privacyAndStorageOverview
            collectionSection
        }
    }

    private var privacyAndStorageOverview: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(
                    localization.string(
                        "settings.privacyOverview.section",
                        defaultValue: "Privacy & Storage"
                    ),
                    systemImage: "lock.shield"
                )
                Spacer()
                Text(encryptedStorageStatusTitle)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(encryptedStorageStatusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(encryptedStorageStatusColor.opacity(0.12), in: Capsule())
                Button {
                    setupDestination = .guide
                } label: {
                    Label(
                        settings.hasCompletedInitialSetup
                            ? localization.string("setup.show", defaultValue: "Setup Guide")
                            : localization.string("setup.continue", defaultValue: "Continue Setup"),
                        systemImage: "questionmark.circle"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(settingsContext == nil)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: "lock.shield.fill")
                        .pluginSettingsRowIconStyle(.green)
                    Text(localization.string(
                        "settings.privacyOverview.summary",
                        defaultValue: "Clipboard data stays encrypted on this Mac; Keychain stores only the key. Accessibility enables pasting, private copy, and optional keyword expansion."
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        showsPrivacyDetails.toggle()
                    } label: {
                        Text(localization.string(
                            "settings.privacyOverview.details",
                            defaultValue: "Details"
                        ))
                    }
                    .buttonStyle(.link)
                }
                .pluginSettingsListRowPadding(interactive: true)

                if showsPrivacyDetails {
                    PluginSettingsListDivider()
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Text(localization.string(
                            "settings.storage.encrypted.title",
                            defaultValue: "Encrypted Local Storage"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.storage.encrypted.description",
                            defaultValue: "History, saved clips, and snippets use a local encrypted database. iCloud Keychain is not required."
                        ))
                        Text(localization.string(
                            "settings.privacy.title",
                            defaultValue: "Privacy Boundaries"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(privacyDescription)
                    }
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .pluginSettingsListRowPadding()
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.string(
            "settings.collection.section",
            defaultValue: "Collection & Security"
        ))
    }

    private var savedLibrarySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.saved.section", defaultValue: "Saved Clips"),
                systemImage: "bookmark"
            )
            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.format(
                            "settings.saved.count",
                            defaultValue: "%d saved clips",
                            controller.savedItems.count
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.saved.description",
                            defaultValue: "Saved clips remain searchable outside History retention. Snippets are managed separately."
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(
                        localization.string("settings.saved.clear", defaultValue: "Clear Saved Clips"),
                        role: .destructive
                    ) {
                        clearRequest = .savedClips
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.savedItems.isEmpty)
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.snippets.section", defaultValue: "Snippets"),
                systemImage: "text.quote"
            )
            VStack(spacing: 0) {
                if let errorMessage = savedLibraryController.fatalErrorMessage
                    ?? savedLibraryController.errorMessage {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                        Text(localization.string(
                            "settings.snippets.description",
                            defaultValue: "Reusable editable templates with optional keywords, tags, and paste-time variables."
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            Button(localization.string(
                                "settings.storage.retry",
                                defaultValue: "Retry"
                            )) {
                                savedLibraryController.retryLoading()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding(interactive: true)
                    PluginSettingsListDivider()
                }

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.format(
                            "settings.snippets.count",
                            defaultValue: "%d snippets",
                            savedLibraryController.items.count
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.snippets.description",
                            defaultValue: "Reusable editable templates with optional keywords, tags, and paste-time variables."
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(localization.string("settings.snippets.manage", defaultValue: "Manage Snippets")) {
                        onManageSnippets?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(onManageSnippets == nil)
                }
                .pluginSettingsListRowPadding(interactive: true)

                PluginSettingsListDivider()

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string(
                            "settings.saved.expansion.title",
                            defaultValue: "Expand Snippet Keywords"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.saved.expansion.description",
                            defaultValue: "Immediately replace an unambiguous snippet keyword as you type. Secure text fields are ignored."
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(keywordExpansionStatusTitle)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(keywordExpansionStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(keywordExpansionStatusColor.opacity(0.12), in: Capsule())
                    if settings.keywordExpansionStatus == .accessibilityRequired {
                        Button(localization.string(
                            "settings.saved.expansion.allowAccess",
                            defaultValue: "Allow Access"
                        )) {
                            _ = ClipboardHistoryAccessibilityCheck.requestTrust(prompt: true)
                            settings.refreshKeywordExpansion()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Toggle("", isOn: $settings.isKeywordExpansionEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .pluginSettingsListRowPadding(interactive: true)
                if let diagnostic = keywordExpansionDiagnosticTitle {
                    Text(diagnostic)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsListRowPadding()
                }
                PluginSettingsListDivider()
                ClipboardSettingsDisclosure(isExpanded: $isSnippetAdvancedExpanded,
                    headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal) {
                    settingPickerRow(
                        title: localization.string("settings.snippets.expandedLimit.title", defaultValue: "Expanded Text Limit"),
                        description: localization.string("settings.snippets.expandedLimit.description", defaultValue: "Limits the final text after variables expand, including previews. Oversized output is rejected, never truncated."),
                        selection: $settings.maximumExpandedTextByteCount
                    ) {
                        ForEach(ClipboardHistorySettingsStore.allowedExpandedTextByteCounts, id: \.self) { count in
                            Text(byteCountTitle(count)).tag(count)
                        }
                    }
                } label: {
                    Text(localization.string("settings.snippets.advanced", defaultValue: "Advanced"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var keywordExpansionStatusTitle: String {
        switch settings.keywordExpansionStatus {
        case .off:
            localization.string("settings.saved.expansion.status.off", defaultValue: "Off")
        case .noKeywords:
            localization.string("settings.saved.expansion.status.noKeywords", defaultValue: "No Keywords")
        case .accessibilityRequired:
            localization.string("permission.accessibility.title", defaultValue: "Permission Needed")
        case .ready:
            localization.string("settings.saved.expansion.status.listening", defaultValue: "Listening")
        case .unavailable:
            localization.string("settings.saved.expansion.status.unavailable", defaultValue: "Unavailable")
        }
    }

    private var keywordExpansionStatusColor: Color {
        switch settings.keywordExpansionStatus {
        case .ready: .green
        case .accessibilityRequired, .unavailable: .orange
        case .off, .noKeywords: .secondary
        }
    }

    private var keywordExpansionDiagnosticTitle: String? {
        guard settings.isKeywordExpansionEnabled else { return nil }
        switch settings.keywordExpansionDiagnostic {
        case .listening:
            return localization.string("settings.expansion.listening", defaultValue: "Waiting for typing in another app.")
        case .receivingTyping:
            return localization.string("settings.expansion.receiving", defaultValue: "Listening for a configured keyword.")
        case .expanded:
            return localization.string("settings.expansion.expanded", defaultValue: "Last keyword expanded successfully.")
        case .unsupportedEditor:
            return localization.string("settings.expansion.unsupported", defaultValue: "This field does not expose a supported, non-secure text editor. Paste the snippet from Clipboard instead.")
        case .focusUnavailable:
            return localization.string("settings.expansion.focusUnavailable", defaultValue: "The focused editor could not be reached. Try typing the keyword again.")
        case .focusOwnershipUnverified:
            return localization.string("settings.expansion.focusOwnershipUnverified", defaultValue: "The focused editor was found, but its app window could not be verified. Paste the snippet from Clipboard instead.")
        case .selectionUnavailable:
            return localization.string("settings.expansion.selection", defaultValue: "This editor does not expose its text selection. Paste the snippet from Clipboard instead.")
        case .contextChanged:
            return localization.string("settings.expansion.contextChanged", defaultValue: "The text or cursor changed before expansion; nothing was replaced.")
        case .templateUnavailable:
            return localization.string("settings.expansion.templateUnavailable", defaultValue: "The snippet is not ready. Retry after it finishes loading.")
        case .replacementUnavailable:
            return localization.string("settings.expansion.replacementUnavailable", defaultValue: "This editor did not allow text replacement. Paste the snippet from Clipboard instead.")
        case nil:
            return nil
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.collection.controls.section", defaultValue: "Collection"),
                systemImage: "clipboard"
            )
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
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var additionalShortcutsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.shortcuts.additional.title", defaultValue: "其他快捷键"),
                systemImage: "keyboard"
            )
            VStack(spacing: 0) {
                ClipboardSettingsDisclosure(
                    isExpanded: $isWindowShortcutsExpanded,
                    headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
                ) {
                    VStack(spacing: 0) {
                        Text(localization.string("panel.shortcuts.group.description", defaultValue: "These shortcuts work only while Clipboard History is focused."))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pluginSettingsListRowPadding()
                        if let context = settingsContext {
                            ForEach(context.shortcutItems.filter {
                                $0.settingsGroupID == ClipboardHistoryPlugin.ShortcutID.panelGroup
                            }) { item in
                                PluginSettingsListDivider()
                                ClipboardSettingsShortcutRow(
                                    title: item.settingsControlTitle ?? item.title,
                                    description: item.description,
                                    systemImage: item.settingsControlSystemImage ?? "keyboard",
                                    bindingText: item.bindingText,
                                    canAssign: true,
                                    canClear: item.canClear,
                                    localization: localization,
                                    warnsAboutGlobalConflicts: false,
                                    onRecord: { context.recordShortcut($0, for: item.id) },
                                    onBeginRecording: { context.beginShortcutRecording(for: item.id) },
                                    onClear: { context.clearShortcut(for: item.id) }
                                )
                            }
                        }
                    }
                } label: {
                    Text(localization.string("panel.shortcuts.group", defaultValue: "Clipboard Window Shortcuts"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)

                PluginSettingsListDivider()

                ClipboardSettingsDisclosure(
                    isExpanded: $isCollectionShortcutsExpanded,
                    headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
                ) {
                    VStack(spacing: 0) {
                        Text(localization.string("settings.shortcuts.collection.description", defaultValue: "可选：控制收集状态或清除历史记录。"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pluginSettingsListRowPadding()
                        if let context = settingsContext {
                            ForEach(ClipboardHistoryPlugin.collectionControlActionIDs, id: \.self) { actionID in
                                if let item = context.actionShortcutItem(actionID: actionID) {
                                    PluginSettingsListDivider()
                                    ClipboardSettingsShortcutRow(
                                        title: item.title,
                                        description: item.description,
                                        systemImage: collectionControlIcon(actionID),
                                        bindingText: item.bindingText,
                                        canAssign: item.canAssign,
                                        canClear: item.canClear,
                                        localization: localization,
                                        onRecord: { context.recordActionShortcut($0, for: actionID) },
                                        onBeginRecording: nil,
                                        onClear: { context.clearActionShortcut(for: actionID) }
                                    )
                                }
                            }
                        }
                    }
                } label: {
                    Text(localization.string("settings.shortcuts.collection.title", defaultValue: "高级控制"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func collectionControlIcon(_ actionID: String) -> String {
        switch actionID {
        case ClipboardHistoryPlugin.ActionID.pauseCollection: "pause.circle"
        case ClipboardHistoryPlugin.ActionID.resumeCollection: "play.circle"
        case ClipboardHistoryPlugin.ActionID.clearAllHistory: "trash"
        default: "playpause"
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

    private var sequentialPasteSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.sequentialPaste.options.section", defaultValue: "Paste Queue"),
                systemImage: "list.number"
            )
            VStack(spacing: 0) {
                if let context = settingsContext,
                   let item = context.shortcutItem(definitionID: "paste-sequentially") {
                    ClipboardSettingsShortcutRow(
                        title: item.settingsControlTitle ?? item.title,
                        description: item.description,
                        systemImage: "list.number",
                        bindingText: item.bindingText,
                        canAssign: true,
                        canClear: item.canClear,
                        localization: localization,
                        onRecord: { context.recordShortcut($0, for: item.id) },
                        onBeginRecording: { context.beginShortcutRecording(for: item.id) },
                        onClear: { context.clearShortcut(for: item.id) }
                    )
                }
                PluginSettingsListDivider()
                sequentialPasteAdvancedOptions
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var sequentialPasteAdvancedOptions: some View {
        ClipboardSettingsDisclosure(
            isExpanded: advancedSectionBinding(.queue),
            headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
        ) {
            VStack(spacing: 0) {
                settingPickerRow(
                    title: localization.string(
                        "settings.sequentialPaste.dismiss.title",
                        defaultValue: "Hide Queue HUD After"
                    ),
                    description: localization.string(
                        "settings.sequentialPaste.dismiss.description",
                        defaultValue: "The movable HUD appears automatically after sequential paste."
                    ),
                    selection: $settings.sequentialHUDDismissal
                ) {
                    ForEach(ClipboardSequentialHUDDismissal.allCases) { option in
                        Text(sequentialHUDDismissalTitle(option)).tag(option)
                    }
                }
                PluginSettingsListDivider()
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string(
                            "settings.sequentialPaste.hidePreview.title",
                            defaultValue: "Hide Content Preview"
                        ))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.sequentialPaste.hidePreview.description",
                            defaultValue: "Show only queue position and controls in the HUD."
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: $settings.hidesSequentialHUDPreview)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .pluginSettingsListRowPadding(interactive: true)
                if let context = settingsContext {
                    ForEach(ClipboardHistoryPlugin.queueControlActionIDs, id: \.self) { actionID in
                        if let item = context.actionShortcutItem(actionID: actionID) {
                            PluginSettingsListDivider()
                            ClipboardSettingsShortcutRow(
                                title: item.title,
                                description: item.description,
                                systemImage: queueControlIcon(actionID),
                                bindingText: item.bindingText,
                                canAssign: item.canAssign,
                                canClear: item.canClear,
                                localization: localization,
                                onRecord: { context.recordActionShortcut($0, for: actionID) },
                                onBeginRecording: nil,
                                onClear: { context.clearActionShortcut(for: actionID) }
                            )
                        }
                    }
                }
            }
        } label: {
            Text(localization.string("settings.queue.advanced", defaultValue: "More Queue Options"))
                .font(PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func queueControlIcon(_ actionID: String) -> String {
        switch actionID {
        case ClipboardHistoryPlugin.ActionID.previousSequentialQueueItem: "backward.end"
        case ClipboardHistoryPlugin.ActionID.skipSequentialQueueItem: "forward.end"
        case ClipboardHistoryPlugin.ActionID.restartSequentialQueue: "arrow.counterclockwise"
        default: "xmark.circle"
        }
    }

    private func sequentialHUDDismissalTitle(
        _ option: ClipboardSequentialHUDDismissal
    ) -> String {
        switch option {
        case .fiveSeconds:
            localization.string("settings.sequentialPaste.dismiss.5", defaultValue: "5 seconds")
        case .tenSeconds:
            localization.string("settings.sequentialPaste.dismiss.10", defaultValue: "10 seconds")
        case .thirtySeconds:
            localization.string("settings.sequentialPaste.dismiss.30", defaultValue: "30 seconds")
        case .never:
            localization.string("settings.sequentialPaste.dismiss.never", defaultValue: "Never")
        }
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
            defaultValue: "暂时无法访问钥匙串不会删除数据；删除加密密钥会使现有历史和已保存项目永久无法读取。文件仅保存路径引用。关键词展开启用时会在本机使用辅助功能观察输入。"
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
        ClipboardSettingsDisclosure(isExpanded: advancedSectionBinding(.retention)) {
            VStack(spacing: 0) {
                settingPickerRow(
                    title: localization.string("settings.retention.maximum.title", defaultValue: "最多保留"),
                    description: localization.string(
                        "settings.retention.maximum.description",
                        defaultValue: "达到条数上限时，会自动移除最早的历史记录。已存项目不受影响。"
                    ),
                    selection: $settings.maximumItemCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedItemCounts, id: \.self) { count in
                        Text(
                            count == ClipboardHistorySettings.noItemCountLimit
                                ? localization.string(
                                    "settings.retention.itemCount.noLimit",
                                    defaultValue: "Unlimited"
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
                        defaultValue: "达到容量上限时移除最早的历史记录。实际保存仍受可用磁盘空间限制。"
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
                        defaultValue: "“永不”仅关闭按时间过期；容量规则仍会移除最早的历史记录。"
                    ),
                    selection: $settings.expiration
                ) {
                    ForEach(ClipboardHistoryExpiration.allCases) { expiration in
                        Text(expirationTitle(expiration)).tag(expiration)
                    }
                }
                PluginSettingsListDivider()
                settingPickerRow(
                    title: localization.string("settings.retention.itemLimit.title", defaultValue: "Per-item Content Limit"),
                    description: localization.string(
                        "settings.retention.itemLimit.description",
                        defaultValue: "Text, images, and embedded content above this explicit limit are not saved; files store references only."
                    ),
                    selection: $settings.maximumItemByteCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedItemByteCounts, id: \.self) { count in
                        Text(byteCountTitle(count)).tag(count)
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader(
                    localization.string("settings.retention.section", defaultValue: "History Limits"),
                    systemImage: "clock.arrow.circlepath"
                )
                Text(retentionSummary)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var retentionSummary: String {
        let itemLimit = settings.maximumItemCount == ClipboardHistorySettings.noItemCountLimit
            ? localization.string("settings.retention.itemCount.noLimit", defaultValue: "Unlimited items")
            : localization.format(
                "settings.retention.itemCount",
                defaultValue: "%d items",
                settings.maximumItemCount
            )
        return [
            itemLimit,
            byteCountTitle(settings.maximumTotalPayloadByteCount),
            expirationTitle(settings.expiration),
        ].joined(separator: " · ")
    }

    private var exclusionsSection: some View {
        ClipboardSettingsDisclosure(isExpanded: advancedSectionBinding(.exclusions)) {
            VStack(spacing: 0) {
                HStack {
                    Text(exclusionsSummary)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        chooseExcludedApplications()
                    } label: {
                        Label(localization.string("common.add", defaultValue: "添加"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .pluginSettingsListRowPadding(interactive: true)

                PluginSettingsListDivider()

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
        } label: {
            HStack {
                sectionHeader(
                    localization.string("settings.exclusions.section", defaultValue: "排除的应用"),
                    systemImage: "app.badge.checkmark"
                )
                Spacer()
                Text(exclusionsSummary)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
    }

    private var exclusionsSummary: String {
        if settings.excludedApplications.isEmpty {
            return localization.string("settings.exclusions.empty", defaultValue: "No excluded apps")
        }
        let names = settings.excludedApplications.prefix(2).map(displayName(for:))
        let remainingCount = settings.excludedApplications.count - names.count
        if remainingCount == 0 {
            return names.joined(separator: ", ")
        }
        return names.joined(separator: ", ") + " +\(remainingCount)"
    }

    private var dataSection: some View {
        let historyUsage = controller.usage
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.data.section", defaultValue: "本机数据"),
                systemImage: "externaldrive"
            )
            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localDataUsageSummary(historyUsage))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.data.historyDescription",
                            defaultValue: "History follows the retention rules above. Saved items are stored separately."
                        ))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pluginSettingsListRowPadding(interactive: true)

                PluginSettingsListDivider()
                ClipboardSettingsDisclosure(
                    isExpanded: $isMaintenanceExpanded,
                    headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
                ) {
                    VStack(spacing: 0) {
                        clearDataRow(
                            title: localization.string("settings.data.clearHistory", defaultValue: "Clear History"),
                            description: localization.string("clear.all.message", defaultValue: "Clears History. Saved clips and snippets are kept. This cannot be undone."),
                            request: .all,
                            disabled: controller.errorMessage != nil || controller.historyItems.isEmpty || controller.isClearingHistory
                        )
                        PluginSettingsListDivider()
                        clearDataRow(
                            title: localization.string("settings.saved.clear", defaultValue: "Clear Saved Clips"),
                            description: localization.string("settings.saved.clear.message", defaultValue: "Removes Saved status from clips in History and permanently deletes Saved-only clips. History and snippets are kept. This cannot be undone."),
                            request: .savedClips,
                            disabled: controller.errorMessage != nil || controller.savedItems.isEmpty || controller.isClearingHistory
                        )
                        PluginSettingsListDivider()
                        clearDataRow(
                            title: localization.string("settings.snippets.clear", defaultValue: "Delete Snippets"),
                            description: localization.string("settings.snippets.clear.message", defaultValue: "Permanently deletes all snippets and their keywords. History and Saved clips are kept. This cannot be undone."),
                            request: .snippets,
                            disabled: savedLibraryController.items.isEmpty || savedLibraryController.errorMessage != nil
                        )
                    }
                } label: {
                    Text(localization.string("settings.data.maintenance", defaultValue: "Clear Data…"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)

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

            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func clearDataRow(
        title: String, description: String,
        request: ClipboardHistorySettingsClearRequest, disabled: Bool
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(description)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(title + "…", role: .destructive) { clearRequest = request }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(disabled)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func localDataUsageSummary(_ usage: ClipboardHistoryUsage) -> String {
        let itemUsage: String
        if settings.maximumItemCount == ClipboardHistorySettings.noItemCountLimit {
            itemUsage = localization.format(
                "settings.retention.itemCount",
                defaultValue: "%d items",
                usage.itemCount
            ) + " · " + localization.string(
                "settings.retention.itemCount.noLimit",
                defaultValue: "Unlimited items"
            )
        } else {
            itemUsage = localization.format(
                "settings.data.savedCount",
                defaultValue: "%d / %d items · %@ / %@",
                usage.itemCount,
                settings.maximumItemCount,
                byteCountTitle(usage.payloadByteCount),
                byteCountTitle(settings.maximumTotalPayloadByteCount)
            )
            return itemUsage
        }
        return itemUsage + " · " + byteCountTitle(usage.payloadByteCount)
            + " / " + byteCountTitle(settings.maximumTotalPayloadByteCount)
    }

    private func advancedSectionBinding(
        _ section: ClipboardHistorySettingsContentSection
    ) -> Binding<Bool> {
        Binding(
            get: {
                section == .data && controller.errorMessage != nil
                    || expandedAdvancedSections.contains(section)
            },
            set: { isExpanded in
                if isExpanded {
                    expandedAdvancedSections.insert(section)
                } else {
                    expandedAdvancedSections.remove(section)
                }
            }
        )
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
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker(title, selection: selection, content: content)
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 180, alignment: .trailing)
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

@MainActor
private struct ClipboardSettingsShortcutRow: View {
    let title: String
    let description: String
    let systemImage: String
    let bindingText: String
    let canAssign: Bool
    let canClear: Bool
    let localization: PluginLocalization
    var warnsAboutGlobalConflicts = true
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onBeginRecording: (() -> Void)?
    let onClear: () -> Void
    @State private var displayedBinding: String?
    @State private var pendingBinding: ShortcutBinding?
    @State private var showsConflictWarning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: systemImage)
                    .pluginSettingsRowIconStyle(.blue)
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(title).font(PluginSettingsTheme.Typography.rowTitle)
                    Text(description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PluginSettingsShortcutRecorderControl(
                    title: title,
                    displayText: displayedBinding ?? bindingText,
                    canAssign: canAssign,
                    canClear: displayedBinding.map { !$0.isEmpty } ?? canClear,
                    clearTitle: localization.string("common.remove", defaultValue: "移除"),
                    onRecord: { binding in
                        if warnsAboutGlobalConflicts && CommonApplicationShortcutBindings.requiresConflictWarning(for: binding) {
                            pendingBinding = binding
                            showsConflictWarning = true
                            return .accepted
                        }
                        return save(binding)
                    },
                    onBeginRecording: {
                        errorMessage = nil
                        onBeginRecording?()
                    },
                    onClear: {
                        onClear()
                        displayedBinding = ""
                        errorMessage = nil
                    }
                )
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .onChange(of: bindingText) { _, _ in displayedBinding = nil }
        .alert(
            localization.format(
                "settings.shortcut.commonConflictWarning.title",
                defaultValue: "仍要使用“%@”？",
                pendingBinding.map { ShortcutFormatter.displayString(for: $0) } ?? ""
            ),
            isPresented: $showsConflictWarning
        ) {
            Button(localization.string("settings.shortcut.commonConflictWarning.confirm", defaultValue: "仍要使用")) {
                if let pendingBinding { _ = save(pendingBinding) }
                pendingBinding = nil
            }
            Button(localization.string("common.cancel", defaultValue: "取消"), role: .cancel) {
                pendingBinding = nil
            }
        } message: {
            Text(localization.string(
                "settings.shortcut.commonConflictWarning.message",
                defaultValue: "这是全局快捷键，可能覆盖其他应用的常用操作。"
            ))
        }
    }

    private func save(_ binding: ShortcutBinding) -> PluginShortcutRecordingResult {
        let result = onRecord(binding)
        switch result {
        case .accepted:
            displayedBinding = ShortcutFormatter.displayString(for: binding)
            errorMessage = nil
        case let .rejected(message):
            errorMessage = message
        }
        return result
    }
}

private enum ClipboardHistorySettingsClearRequest: String, Identifiable {
    case all
    case savedClips
    case snippets
    case resetUnreadable

    var id: String { rawValue }
}

struct ClipboardSettingsDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    private let headerHorizontalPadding: CGFloat
    private let label: Label
    private let content: Content

    init(
        isExpanded: Binding<Bool>,
        headerHorizontalPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        _isExpanded = isExpanded
        self.headerHorizontalPadding = headerHorizontalPadding
        self.content = content()
        self.label = label()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            label
        }
        .disclosureGroupStyle(ClipboardSettingsDisclosureStyle(headerHorizontalPadding: headerHorizontalPadding))
    }
}

private struct ClipboardSettingsDisclosureStyle: DisclosureGroupStyle {
    let headerHorizontalPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: configuration.isExpanded ? PluginSettingsTheme.Spacing.sectionHeaderContent : 0) {
            Button {
                // Keep the full-row hit target without fading/sliding the form
                // or interpolating its scroll position as sections change size.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, headerHorizontalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isExpanded ? .isSelected : [])

            if configuration.isExpanded {
                configuration.content
                    .transition(.identity)
            }
        }
    }
}
