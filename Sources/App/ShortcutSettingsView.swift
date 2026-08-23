import SwiftUI
import MacToolsPluginKit

struct CommonShortcutBindingWarning: Identifiable {
    let id = UUID()
    let shortcutID: String
    let binding: ShortcutBinding
}

func commonShortcutBindingWarningAlert(
    _ warning: CommonShortcutBindingWarning,
    onConfirm: @escaping () -> Void
) -> Alert {
    Alert(
        title: Text(AppL10n.settingsFormat(
            "shortcuts.commonConflictWarning.title",
            defaultValue: "仍要使用“%@”？",
            ShortcutFormatter.displayString(for: warning.binding)
        )),
        message: Text(AppL10n.settings(
            "shortcuts.commonConflictWarning.message",
            defaultValue: "这是全局快捷键，可能覆盖其他应用的常用操作。"
        )),
        primaryButton: .default(
            Text(AppL10n.settings(
                "shortcuts.commonConflictWarning.confirm",
                defaultValue: "仍要使用"
            )),
            action: onConfirm
        ),
        secondaryButton: .cancel(
            Text(AppL10n.settings(
                "shortcuts.commonConflictWarning.cancel",
                defaultValue: "取消"
            ))
        )
    )
}

private enum ShortcutSettingsLayout {
    static let recorderWidth = PluginSettingsTheme.Size.shortcutRecorderWidth
    static let controlLabelMaxWidth: CGFloat = 160
    static let groupedControlMinWidth: CGFloat = 260
    static let groupedControlMaxWidth: CGFloat = 380
    static let summaryMinWidth: CGFloat = 220
    static let actionButtonSize: CGFloat = 22
    static let actionButtonsWidth: CGFloat = 50
}

struct ShortcutSettingsView: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"), systemImage: "command")
                        .font(PluginSettingsTheme.Typography.pageTitle)

                    Text(AppL10n.settings(
                        "shortcuts.description",
                        defaultValue: "为常用动作配置全局快捷键。编辑后立即生效，必要项不可删除。"
                    ))
                        .font(PluginSettingsTheme.Typography.pageDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PluginSettingsTheme.Spacing.cardContent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsCardBackground(.standard)

                ShortcutSettingsRowsView(pluginHost: pluginHost, items: pluginHost.shortcutItems)
                .pluginSettingsCardBackground(.standard)
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
        }
        .background(SettingsStyle.contentBackground)
    }
}

enum ActionShortcutFilter: String, CaseIterable, Identifiable {
    case all
    case assigned
    case unassigned
    case conflicted
    case unavailable

    var id: Self { self }

    var title: String {
        switch self {
        case .all: FeatureL10n.string("全部")
        case .assigned: FeatureL10n.string("已分配")
        case .unassigned: FeatureL10n.string("未分配")
        case .conflicted: FeatureL10n.string("冲突")
        case .unavailable: FeatureL10n.string("不可用")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.3x3"
        case .assigned: "checkmark.circle"
        case .unassigned: "circle.dashed"
        case .conflicted: "exclamationmark.triangle"
        case .unavailable: "slash.circle"
        }
    }

    var iconTint: Color {
        switch self {
        case .all: .accentColor
        case .assigned: .green
        case .unassigned: .blue
        case .conflicted: .orange
        case .unavailable: .secondary
        }
    }

    func includes(_ status: ActionShortcutCatalogStatus) -> Bool {
        switch (self, status) {
        case (.all, _), (.assigned, .assigned), (.unassigned, .unassigned),
             (.conflicted, .conflicted), (.unavailable, .unavailable):
            true
        default:
            false
        }
    }
}

private struct PendingActionShortcutReplacement: Identifiable {
    let reference: ActionReference
    let assignmentID: UUID?
    let binding: ShortcutBinding
    let ownerDescription: String

    var id: String { assignmentID?.uuidString ?? reference.key.id }
}

struct ActionShortcutSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @State private var query = ""
    @State private var filter: ActionShortcutFilter = .all
    @State private var groups: [ActionShortcutGroup] = []
    @State private var pendingReplacement: PendingActionShortcutReplacement?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: SettingsPageLayout.introductionContentSpacing
            ) {
                introduction
                controls

                if let error = pluginHost.actionShortcutLoadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                        .padding(PluginSettingsTheme.Spacing.cardContent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsCardBackground(.standard)
                }

                if groups.isEmpty {
                    ContentUnavailableView(
                        FeatureL10n.string("没有匹配的操作"),
                        systemImage: "command",
                        description: Text(FeatureL10n.string("调整搜索词或筛选条件后重试。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ForEach(groups, id: \.providerID) { group in
                        actionGroup(group)
                    }
                }
            }
            .padding(.horizontal, SettingsPageLayout.horizontalInset)
            .padding(.vertical, SettingsPageLayout.verticalInset)
        }
        .background(SettingsStyle.contentBackground)
        .onAppear(perform: refreshGroups)
        .onChange(of: pluginHost.actionShortcutCatalogItems) { _, _ in refreshGroups() }
        .onChange(of: query) { _, _ in refreshGroups() }
        .onChange(of: filter) { _, _ in refreshGroups() }
        .alert(item: $pendingReplacement) { replacement in
            Alert(
                title: Text(FeatureL10n.string("替换快捷键？")),
                message: Text(FeatureL10n.format(
                    "此快捷键已分配给“%@”。替换后，原操作将不再使用它。",
                    replacement.ownerDescription
                )),
                primaryButton: .destructive(Text(FeatureL10n.string("替换"))) {
                    _ = pluginHost.setActionShortcutBinding(
                        replacement.binding,
                        to: replacement.reference,
                        assignmentID: replacement.assignmentID,
                        replacingConflictingActionAssignments: true
                    )
                },
                secondaryButton: .cancel()
            )
        }
        .accessibilityIdentifier("mactools.actions-and-shortcuts")
    }

    private var introduction: some View {
        SettingsPageIntroduction(
            configuration: SettingsPageIntroductionConfiguration(
                description: FeatureL10n.string(
                    "查找 MacTools 与插件操作，并在同一个冲突空间中管理全局快捷键。"
                )
            )
        )
    }

    private var controls: some View {
        SettingsSearchFilterBar(
            searchText: $query,
            isSearchFocused: $isSearchFocused,
            searchPrompt: FeatureL10n.string("搜索操作、插件或快捷键"),
            clearSearchHelp: AppL10n.search(
                "search.clear",
                defaultValue: "清除搜索"
            ),
            searchAccessibilityIdentifier: "mactools.actions.search"
        ) {
            SettingsFilterChipsRow(
                accessibilityLabel: FeatureL10n.string("筛选")
            ) {
                ForEach(ActionShortcutFilter.allCases) { option in
                    SettingsFilterChip(
                        title: option.title,
                        systemImage: option.systemImage,
                        iconTint: option.iconTint,
                        count: countsByFilter[option] ?? 0,
                        isSelected: filter == option,
                        accessibilityIdentifier: "mactools.actions.filter.\(option.rawValue)",
                        action: { filter = option }
                    )
                }
            }
        }
    }

    private var countsByFilter: [ActionShortcutFilter: Int] {
        Dictionary(uniqueKeysWithValues: ActionShortcutFilter.allCases.map { option in
            (option, queryMatchingItems.filter { option.includes($0.status) }.count)
        })
    }

    private var queryMatchingItems: [ActionShortcutCatalogItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return pluginHost.actionShortcutCatalogItems
        }

        return pluginHost.actionShortcutCatalogItems.filter { item in
            [item.title, item.ownerTitle, item.description, item.bindingText]
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    private func refreshGroups() {
        let matching = queryMatchingItems.filter { filter.includes($0.status) }

        var order: [String] = []
        var groupedItems: [String: [ActionShortcutCatalogItem]] = [:]
        for item in matching {
            let providerID = item.reference.key.providerID
            if groupedItems[providerID] == nil {
                order.append(providerID)
            }
            groupedItems[providerID, default: []].append(item)
        }
        groups = order.compactMap { providerID in
            guard let items = groupedItems[providerID], let first = items.first else {
                return nil
            }
            return ActionShortcutGroup(
                providerID: providerID,
                title: first.ownerTitle,
                items: items
            )
        }
    }

    private func actionGroup(_ group: ActionShortcutGroup) -> some View {
        let appearance = pluginHost.actionOwnerAppearance(providerID: group.providerID)
        let ownerReference = group.items.first(where: {
            pluginHost.canPresentActionOwner(for: $0.reference)
        })?.reference

        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: 8) {
                Image(systemName: PluginSystemImage.resolvedName(appearance.systemImage))
                    .foregroundStyle(appearance.iconTint)
                    .frame(width: 18)

                Text(group.title)
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)

                if let ownerReference {
                    Button {
                        pluginHost.presentActionOwner(for: ownerReference)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(FeatureL10n.string("打开所属功能的设置"))
                    .accessibilityLabel(FeatureL10n.string("打开所属功能的设置"))
                }

                Spacer(minLength: 0)
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    ActionShortcutCatalogRow(
                        pluginHost: pluginHost,
                        item: item,
                        onRecord: { binding in record(binding, for: item) },
                        onClear: {
                            pluginHost.clearActionShortcut(
                                for: item.reference,
                                assignmentID: item.assignmentID
                            )
                        }
                    )
                    if index < group.items.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private func record(
        _ binding: ShortcutBinding,
        for item: ActionShortcutCatalogItem
    ) -> PluginShortcutRecordingResult {
        switch pluginHost.setActionShortcutBinding(
            binding,
            to: item.reference,
            assignmentID: item.assignmentID
        ) {
        case .success:
            return .accepted
        case let .failure(.conflict(ownerDescription)):
            pendingReplacement = PendingActionShortcutReplacement(
                reference: item.reference,
                assignmentID: item.assignmentID,
                binding: binding,
                ownerDescription: ownerDescription
            )
            return .accepted
        case let .failure(error):
            return .rejected(error.localizedDescription)
        }
    }
}

struct PluginActionShortcutRowsContent: View {
    @ObservedObject var pluginHost: PluginHost
    let providerID: String
    let actionIDs: Set<String>
    var hidesNeutralStatusBadges = false
    @State private var pendingReplacement: PendingActionShortcutReplacement?

    private var items: [ActionShortcutCatalogItem] {
        pluginHost.actionShortcutCatalogItems.filter { item in
            item.reference.key.providerID == providerID
                && actionIDs.contains(item.reference.key.actionID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = pluginHost.actionShortcutLoadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .pluginSettingsListRowPadding(interactive: false)
            } else if items.isEmpty {
                ContentUnavailableView(
                    FeatureL10n.string("没有匹配的操作"),
                    systemImage: "command"
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ActionShortcutCatalogRow(
                        pluginHost: pluginHost,
                        item: item,
                        displaysRunLink: false,
                        hidesNeutralStatusBadge: hidesNeutralStatusBadges,
                        onRecord: { binding in record(binding, for: item) },
                        onClear: {
                            pluginHost.clearActionShortcut(
                                for: item.reference,
                                assignmentID: item.assignmentID
                            )
                        }
                    )
                    if index < items.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
        .alert(item: $pendingReplacement) { replacement in
            Alert(
                title: Text(FeatureL10n.string("替换快捷键？")),
                message: Text(FeatureL10n.format(
                    "此快捷键已分配给“%@”。替换后，原操作将不再使用它。",
                    replacement.ownerDescription
                )),
                primaryButton: .destructive(Text(FeatureL10n.string("替换"))) {
                    _ = pluginHost.setActionShortcutBinding(
                        replacement.binding,
                        to: replacement.reference,
                        assignmentID: replacement.assignmentID,
                        replacingConflictingActionAssignments: true
                    )
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func record(
        _ binding: ShortcutBinding,
        for item: ActionShortcutCatalogItem
    ) -> PluginShortcutRecordingResult {
        switch pluginHost.setActionShortcutBinding(
            binding,
            to: item.reference,
            assignmentID: item.assignmentID
        ) {
        case .success:
            return .accepted
        case let .failure(.conflict(ownerDescription)):
            pendingReplacement = PendingActionShortcutReplacement(
                reference: item.reference,
                assignmentID: item.assignmentID,
                binding: binding,
                ownerDescription: ownerDescription
            )
            return .accepted
        case let .failure(error):
            return .rejected(error.localizedDescription)
        }
    }
}
private struct ActionShortcutGroup {
    let providerID: String
    let title: String
    let items: [ActionShortcutCatalogItem]
}

private struct ActionShortcutCatalogRow: View {
    private enum Layout {
        static let recorderWidth = PluginSettingsTheme.Size.shortcutRecorderWidth
        static let actionButtonSize: CGFloat = 22
    }

    @ObservedObject var pluginHost: PluginHost
    let item: ActionShortcutCatalogItem
    var displaysRunLink = true
    var hidesNeutralStatusBadge = false
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: PluginSystemImage.resolvedName(item.systemImage))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(
                    alignment: .leading,
                    spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                ) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .lineLimit(1)
                        if ActionShortcutStatusBadgePolicy.shouldShow(
                            item.status,
                            hidesNeutralStatus: hidesNeutralStatusBadge
                        ) {
                            statusBadge
                        }
                    }

                    Text(supportingText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(supportingColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PluginShortcutRecorder(
                    title: item.title,
                    displayText: item.bindingText,
                    minWidth: Layout.recorderWidth,
                    onRecord: onRecord
                )
                .frame(width: Layout.recorderWidth)
                .disabled(!item.canAssign || pluginHost.actionShortcutLoadError != nil)

                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Layout.actionButtonSize, height: Layout.actionButtonSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(FeatureL10n.string("清除快捷键"))
                .opacity(item.bindingText.isEmpty ? 0 : 1)
                .disabled(
                    item.bindingText.isEmpty
                        || pluginHost.actionShortcutLoadError != nil
                )
            }

            if displaysRunLink {
                ActionRunLinkControl(
                    pluginHost: pluginHost,
                    reference: item.reference,
                    displaysUnavailableReason: false
                )
                .padding(.leading, 24 + PluginSettingsTheme.Spacing.rowContentControl)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(statusTitle)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var statusTitle: String {
        switch item.status {
        case .assigned: FeatureL10n.string("已分配")
        case .unassigned: FeatureL10n.string("未分配")
        case .conflicted: FeatureL10n.string("冲突")
        case .unavailable: FeatureL10n.string("不可用")
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .assigned: .green
        case .unassigned: .secondary
        case .conflicted: .orange
        case .unavailable: .red
        }
    }

    private var supportingColor: Color {
        switch item.status {
        case .assigned, .unassigned:
            .secondary
        case .conflicted:
            .orange
        case .unavailable:
            .red
        }
    }

    private var supportingText: String {
        switch item.status {
        case .assigned, .unassigned:
            [item.description, item.permissionSummary]
                .compactMap { $0 }
                .joined(separator: " · ")
        case let .conflicted(owner):
            FeatureL10n.format("与“%@”冲突。", owner)
        case let .unavailable(reason):
            reason ?? FeatureL10n.string("此操作当前不可用。")
        }
    }
}

enum ActionShortcutStatusBadgePolicy {
    static func shouldShow(
        _ status: ActionShortcutCatalogStatus,
        hidesNeutralStatus: Bool
    ) -> Bool {
        guard hidesNeutralStatus else { return true }
        switch status {
        case .assigned, .unassigned:
            return false
        case .conflicted, .unavailable:
            return true
        }
    }
}

struct ShortcutSettingsRowsView: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [ShortcutSettingsItem]
    var alignsWithActionRows = false
    @State private var pendingWarning: CommonShortcutBindingWarning?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ShortcutSettingsStandardRow(
                    item: item,
                    recordShortcut: { binding in
                        configure(item, binding: binding)
                    },
                    onBeginRecording: {
                        pluginHost.clearShortcutError(for: item.id)
                    },
                    onClear: {
                        clear(item)
                    },
                    onReset: {
                        reset(item)
                    },
                    alignsWithActionRows: alignsWithActionRows
                )
                .pluginSettingsSearchAnchor(
                    pluginID: item.pluginID,
                    entryID: item.id
                )

                if index < items.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
        .alert(item: $pendingWarning) { warning in
            commonShortcutBindingWarningAlert(warning) {
                guard let item = items.first(where: { $0.id == warning.shortcutID }) else {
                    return
                }
                _ = save(item, binding: warning.binding)
            }
        }
    }

    private func configure(_ item: ShortcutSettingsItem, binding: ShortcutBinding) -> String? {
        if MacToolsReservedShortcutBindings.requiresConflictWarning(for: binding) {
            pendingWarning = CommonShortcutBindingWarning(shortcutID: item.id, binding: binding)
            return nil
        }

        return save(item, binding: binding)
    }

    private func save(_ item: ShortcutSettingsItem, binding: ShortcutBinding) -> String? {
        pluginHost.clearShortcutError(for: item.id)
        return pluginHost.setShortcutBindingAndReturnError(binding, for: item.id)
    }

    private func clear(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.clearShortcut(for: item.id)
    }

    private func reset(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.resetShortcut(for: item.id)
    }
}

struct GroupedShortcutSettingsRowsView: View {
    @ObservedObject var pluginHost: PluginHost
    let groups: [ShortcutSettingsGroup]
    @State private var pendingWarning: CommonShortcutBindingWarning?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                GroupedShortcutSettingsRow(
                    group: group,
                    recordShortcut: configure,
                    onBeginRecording: { item in
                        pluginHost.clearShortcutError(for: item.id)
                    },
                    onClear: clear,
                    onReset: reset
                )
                .pluginSettingsSearchAnchor(
                    pluginID: group.items.first?.pluginID ?? "",
                    entryID: group.id
                )

                if index < groups.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
        .alert(item: $pendingWarning) { warning in
            commonShortcutBindingWarningAlert(warning) {
                guard let item = groups
                    .flatMap(\.items)
                    .first(where: { $0.id == warning.shortcutID })
                else {
                    return
                }
                _ = save(item, binding: warning.binding)
            }
        }
    }

    private func configure(_ item: ShortcutSettingsItem, binding: ShortcutBinding) -> String? {
        if MacToolsReservedShortcutBindings.requiresConflictWarning(for: binding) {
            pendingWarning = CommonShortcutBindingWarning(shortcutID: item.id, binding: binding)
            return nil
        }

        return save(item, binding: binding)
    }

    private func save(_ item: ShortcutSettingsItem, binding: ShortcutBinding) -> String? {
        pluginHost.clearShortcutError(for: item.id)
        return pluginHost.setShortcutBindingAndReturnError(binding, for: item.id)
    }

    private func clear(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.clearShortcut(for: item.id)
    }

    private func reset(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.resetShortcut(for: item.id)
    }
}

struct ShortcutSettingsGroup: Identifiable {
    let id: String
    let title: String
    let description: String?
    let items: [ShortcutSettingsItem]
}

private struct ShortcutSettingsStandardRow: View {
    let item: ShortcutSettingsItem
    let recordShortcut: (ShortcutBinding) -> String?
    let onBeginRecording: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void
    let alignsWithActionRows: Bool

    private var supportingText: String {
        item.errorMessage ?? item.description
    }

    private var supportingColor: Color {
        item.errorMessage == nil ? .secondary : .red
    }

    private var rowHelpText: String {
        [item.title, supportingText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                summary
                    .frame(minWidth: ShortcutSettingsLayout.summaryMinWidth)
                shortcutControl
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                summary
                shortcutControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if alignsWithActionRows, let systemImage = item.settingsControlSystemImage {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: 8) {
                    Text(summaryTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summaryTitle)

                    if item.isRequired {
                        ShortcutStatusBadge(text: AppL10n.settings("shortcuts.required", defaultValue: "必填"))
                    }
                }

                if !supportingText.isEmpty {
                    Text(supportingText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(supportingColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(supportingText)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .help(rowHelpText)
    }

    private var summaryTitle: String {
        if alignsWithActionRows, let title = item.settingsControlTitle {
            return title
        }
        return item.title
    }

    private var shortcutControl: some View {
        ShortcutBindingControl(
            item: item,
            onRecord: { binding in
                PluginShortcutRecordingResult.from(
                    errorMessage: recordShortcut(binding)
                )
            },
            onBeginRecording: onBeginRecording,
            onReset: onReset,
            onClear: onClear,
            title: alignsWithActionRows ? nil : item.settingsControlTitle,
            systemImage: alignsWithActionRows ? nil : item.settingsControlSystemImage
        )
    }
}

struct GroupedShortcutSettingsRow: View {
    private enum Layout {
        static let spacing = PluginSettingsTheme.Spacing.rowContentControl
        static let summaryIdealWidth: CGFloat = 120
        static let controlMinWidth = ShortcutSettingsLayout.groupedControlMinWidth
        static let controlMaxWidth = ShortcutSettingsLayout.groupedControlMaxWidth
    }

    let group: ShortcutSettingsGroup
    let recordShortcut: (ShortcutSettingsItem, ShortcutBinding) -> String?
    let onBeginRecording: (ShortcutSettingsItem) -> Void
    let onClear: (ShortcutSettingsItem) -> Void
    let onReset: (ShortcutSettingsItem) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Layout.spacing) {
                groupSummary
                fixedWidthControls
            }

            VStack(alignment: .leading, spacing: Layout.spacing) {
                groupSummary
                adaptiveControls
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupSummary: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(group.title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.title)

            if !supportingText.isEmpty {
                Text(supportingText)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(supportingColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(supportingText)
            }
        }
        .frame(
            minWidth: 0,
            idealWidth: Layout.summaryIdealWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var fixedWidthControls: some View {
        HStack(alignment: .center, spacing: Layout.spacing) {
            ForEach(group.items) { item in
                shortcutControl(for: item)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var adaptiveControls: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(
                        minimum: Layout.controlMinWidth,
                        maximum: Layout.controlMaxWidth
                    ),
                    spacing: Layout.spacing,
                    alignment: .leading
                )
            ],
            alignment: .leading,
            spacing: Layout.spacing
        ) {
            ForEach(group.items) { item in
                shortcutControl(for: item)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func shortcutControl(for item: ShortcutSettingsItem) -> some View {
        ShortcutBindingControl(
            item: item,
            onRecord: { binding in
                PluginShortcutRecordingResult.from(
                    errorMessage: recordShortcut(item, binding)
                )
            },
            onBeginRecording: { onBeginRecording(item) },
            onReset: { onReset(item) },
            onClear: { onClear(item) },
            title: item.settingsControlTitle,
            systemImage: item.settingsControlSystemImage
        )
    }

    private var supportingText: String {
        let messages = group.items.compactMap(\.errorMessage)
        if !messages.isEmpty {
            return messages.joined(separator: "；")
        }

        return group.description ?? ""
    }

    private var supportingColor: Color {
        group.items.contains(where: { $0.errorMessage != nil }) ? .red : .secondary
    }
}

private struct ShortcutBindingControl: View {
    let item: ShortcutSettingsItem
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onBeginRecording: () -> Void
    let onReset: () -> Void
    let onClear: () -> Void
    var title: String? = nil
    var systemImage: String? = nil

    @ViewBuilder
    var body: some View {
        if hasControlLabel {
            PluginSettingsShortcutControlLayout(
                maximumLabelWidth: ShortcutSettingsLayout.controlLabelMaxWidth
            ) {
                controlLabel
                recorderButton
                actionButtons
            }
        } else {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                recorderButton
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var controlLabel: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .pluginSettingsRowIconStyle(.secondary)
            }

            if let title {
                Text(title)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(title ?? item.title)
    }

    private var recorderButton: some View {
        PluginShortcutRecorder(
            title: title ?? item.title,
            displayText: item.bindingText,
            minWidth: ShortcutSettingsLayout.recorderWidth,
            onRecord: onRecord,
            onBeginRecording: onBeginRecording
        )
        .frame(width: ShortcutSettingsLayout.recorderWidth)
    }

    private var hasControlLabel: Bool {
        title != nil || systemImage != nil
    }

    @ViewBuilder
    private var actionButtons: some View {
        if shouldShowReset || item.canClear {
            HStack(spacing: 6) {
                if shouldShowReset {
                    ShortcutInlineActionButton(
                        systemName: "arrow.counterclockwise",
                        helpText: AppL10n.settings("shortcuts.resetHelp", defaultValue: "重置为默认快捷键"),
                        action: onReset
                    )
                }

                if item.canClear {
                    ShortcutInlineActionButton(
                        systemName: "xmark.circle.fill",
                        helpText: AppL10n.settings("shortcuts.clearHelp", defaultValue: "清除快捷键"),
                        action: onClear
                    )
                }
            }
            .frame(width: actionButtonsWidth, alignment: .leading)
        }
    }

    private var shouldShowReset: Bool {
        !item.usesDefaultValue
    }

    private var actionButtonsWidth: CGFloat {
        shouldShowReset && item.canClear
            ? ShortcutSettingsLayout.actionButtonsWidth
            : ShortcutSettingsLayout.actionButtonSize
    }
}

private struct ShortcutStatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(SettingsStyle.activeControlBackground)
            )
    }
}

private struct ShortcutInlineActionButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(PluginSettingsTheme.Typography.rowIcon)
                .symbolRenderingMode(.monochrome)
                .frame(
                    width: ShortcutSettingsLayout.actionButtonSize,
                    height: ShortcutSettingsLayout.actionButtonSize
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .help(helpText)
    }
}
