import SwiftUI
import MacToolsPluginKit

// MARK: - Grouping

/// Data for one category card. The view derives it from the candidate list and holds no extra state.
struct DiskCleanCategoryGroup: Identifiable, Equatable, Sendable {
    let category: DiskCleanCategoryID
    let candidates: [DiskCleanCandidate]
    let selectableCount: Int
    let selectedCount: Int
    let selectedEstimatedBytes: Int64

    var id: String { category.rawValue }

    /// Grouped by `DiskCleanCategoryID.displayOrder` (low risk → high). Empty categories are omitted.
    static func groups(
        candidates: [DiskCleanCandidate],
        selection: DiskCleanSelectionProjection
    ) -> [DiskCleanCategoryGroup] {
        let candidatesByCategory = Dictionary(grouping: candidates, by: \.category)
        return DiskCleanCategoryID.displayOrder.compactMap { category in
            guard let items = candidatesByCategory[category], !items.isEmpty else { return nil }
            let selected = items.filter { selection.isSelected($0.id) }
            return DiskCleanCategoryGroup(
                category: category,
                candidates: items,
                selectableCount: items.filter { selection.isSelectable($0.id) }.count,
                selectedCount: selected.count,
                selectedEstimatedBytes: selected.reduce(0) { $0 + max($1.estimatedBytes, 0) }
            )
        }
    }
}

// MARK: - Category card list

/// Category card list on the detail page (design §8.3 item 3).
struct DiskCleanCategoryListView: View {
    let groups: [DiskCleanCategoryGroup]
    let selection: DiskCleanSelectionProjection
    /// Per-item terminal status from the last run, used for badges such as "content changed".
    let outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome]
    let localization: PluginLocalization
    let isInteractionEnabled: Bool
    let onToggleCandidate: (DiskCleanCandidate.ID, Bool) -> Void
    let onToggleCategory: (DiskCleanCategoryID, Bool) -> Void

    @Binding var expandedCategories: Set<DiskCleanCategoryID>

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            ForEach(groups) { group in
                DiskCleanCategoryCard(
                    group: group,
                    state: selection.state(of: group.category),
                    selection: selection,
                    outcomesByCandidateID: outcomesByCandidateID,
                    localization: localization,
                    isInteractionEnabled: isInteractionEnabled,
                    isExpanded: expandedCategories.contains(group.category),
                    onToggleExpanded: {
                        if expandedCategories.contains(group.category) {
                            expandedCategories.remove(group.category)
                        } else {
                            expandedCategories.insert(group.category)
                        }
                    },
                    onToggleCandidate: onToggleCandidate,
                    onToggleCategory: onToggleCategory
                )
            }
        }
    }
}

// MARK: - Category cards

private struct DiskCleanCategoryCard: View {
    let group: DiskCleanCategoryGroup
    let state: DiskCleanCategorySelectionState
    let selection: DiskCleanSelectionProjection
    let outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome]
    let localization: PluginLocalization
    let isInteractionEnabled: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onToggleCandidate: (DiskCleanCandidate.ID, Bool) -> Void
    let onToggleCategory: (DiskCleanCategoryID, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                PluginSettingsListDivider()
                candidateRows
            }
        }
        .pluginSettingsCardBackground(.standard)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            DiskCleanTriStateCheckbox(
                state: state,
                // "Select all" = select every low-risk item in this category; if anything is already selected, one click clears all.
                // Tri-state checkboxes must never feel like a no-op click, so both directions always produce a change.
                onToggle: { onToggleCategory(group.category, !state.isChecked) },
                help: checkboxHelp
            )
            .disabled(!isInteractionEnabled || !state.isSelectable)

            Image(systemName: group.category.symbolName)
                .pluginSettingsRowIconStyle()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(group.category.title(localization: localization))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(group.category.consequence(localization: localization))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(countSummary)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Text(DiskCleanFormat.approximateBytes(group.selectedEstimatedBytes, localization: localization))
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .frame(width: DiskCleanFormat.byteColumnWidth, alignment: .trailing)

            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(PluginSettingsTheme.Typography.rowIcon)
            }
            .buttonStyle(.borderless)
            .help(
                isExpanded
                    ? localization.string("detail.category.collapse", defaultValue: "收起项目")
                    : localization.string("detail.category.expand", defaultValue: "展开项目")
            )
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var candidateRows: some View {
        VStack(spacing: 0) {
            ForEach(group.candidates) { candidate in
                DiskCleanCandidateRow(
                    candidate: candidate,
                    isSelected: selection.isSelected(candidate.id),
                    isSelectable: selection.isSelectable(candidate.id),
                    outcome: outcomesByCandidateID[candidate.id],
                    localization: localization,
                    isInteractionEnabled: isInteractionEnabled,
                    onToggle: { onToggleCandidate(candidate.id, $0) }
                )
                if candidate.id != group.candidates.last?.id {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    private var countSummary: String {
        localization.format(
            "detail.category.counts",
            defaultValue: "共 %d 项 · 可清理 %d 项 · 已选 %d 项",
            group.candidates.count,
            group.selectableCount,
            group.selectedCount
        )
    }

    private var checkboxHelp: String {
        state.isChecked
            ? localization.string("detail.category.deselectAll", defaultValue: "取消选择本类全部项目")
            : localization.string("detail.category.selectLowRisk", defaultValue: "选中本类所有低风险项目")
    }
}

// MARK: - Candidate row

private struct DiskCleanCandidateRow: View {
    let candidate: DiskCleanCandidate
    let isSelected: Bool
    let isSelectable: Bool
    let outcome: DiskCleanExecutionItemResult.Outcome?
    let localization: PluginLocalization
    let isInteractionEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var isExplanationExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Toggle("", isOn: Binding(get: { isSelected }, set: { onToggle($0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!isInteractionEnabled || !isSelectable)

                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(candidate.displayName)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(candidate.path)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if !badges.isEmpty {
                        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                            ForEach(badges) { badge in
                                DiskCleanBadgeLabel(badge: badge)
                            }
                        }
                    }
                }

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                Text(sizeText)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(candidate.sizeResult == nil ? Color.secondary : Color.primary)
                    .frame(width: DiskCleanFormat.byteColumnWidth, alignment: .trailing)

                Button {
                    isExplanationExpanded.toggle()
                } label: {
                    Image(systemName: isExplanationExpanded ? "info.circle.fill" : "info.circle")
                        .font(PluginSettingsTheme.Typography.rowIcon)
                        .foregroundStyle(isExplanationExpanded ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(localization.string("candidate.action.explain", defaultValue: "规则解释与详情"))
            }
            .pluginSettingsListRowPadding()

            if isExplanationExpanded, let explanation = candidate.explanation {
                VStack(alignment: .leading, spacing: 6) {
                    PluginSettingsListDivider()
                        .padding(.vertical, 2)

                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        Text(localization.string("candidate.explain.tier", defaultValue: "安全级别："))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        Text(explanation.safetyTier.title(localization: localization))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(explanation.safetyTier == .safe ? Color.green : Color.orange)

                        Text("·")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)

                        Text(localization.string("candidate.explain.confidence", defaultValue: "置信度："))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        Text(confidenceText(explanation.confidence))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)

                        if explanation.requiresFullDiskAccess {
                            Text("·")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(localization.string("candidate.explain.fda", defaultValue: "需要完全磁盘访问权限"))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 4) {
                            Text(localization.string("candidate.explain.whyMatched", defaultValue: "匹配原因："))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(explanation.whyMatched)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(alignment: .top, spacing: 4) {
                            Text(localization.string("candidate.explain.consequence", defaultValue: "删除后果："))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(explanation.consequence)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let regen = explanation.regeneration {
                            HStack(alignment: .top, spacing: 4) {
                                Text(localization.string("candidate.explain.regeneration", defaultValue: "重建方式："))
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                Text(regen)
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                        } label: {
                            Label(localization.string("candidate.action.reveal", defaultValue: "在访达中显示"), systemImage: "folder")
                                .font(PluginSettingsTheme.Typography.controlLabel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(candidate.path, forType: .string)
                        } label: {
                            Label(localization.string("candidate.action.copyPath", defaultValue: "拷贝路径"), systemImage: "doc.on.doc")
                                .font(PluginSettingsTheme.Typography.controlLabel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
            }
        }
    }

    private func confidenceText(_ confidence: DiskCleanConfidence) -> String {
        switch confidence {
        case .high:
            return localization.string("confidence.high", defaultValue: "高")
        case .medium:
            return localization.string("confidence.medium", defaultValue: "中")
        case .low:
            return localization.string("confidence.low", defaultValue: "低")
        }
    }

    /// Unresolved sizes show "calculating…" rather than "0 bytes"—the latter would look like an empty item.
    private var sizeText: String {
        guard candidate.sizeResult != nil else {
            return localization.string("detail.candidate.sizing", defaultValue: "计算中…")
        }
        return DiskCleanFormat.approximateBytes(candidate.estimatedBytes, localization: localization)
    }

    private var badges: [DiskCleanBadge] {
        DiskCleanBadge.badges(for: candidate, outcome: outcome, localization: localization)
    }
}

// MARK: - Badges

struct DiskCleanBadge: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral
        case warning
    }

    let id: String
    let text: String
    let tone: Tone

    /// Per-item badges (design §8.3): in use / whitelist / protected / partial-reason / content changed / mount point / calculating.
    ///
    /// Order is priority: first "what happened on the last cleanup", then "why it cannot be selected now".
    static func badges(
        for candidate: DiskCleanCandidate,
        outcome: DiskCleanExecutionItemResult.Outcome?,
        localization: PluginLocalization
    ) -> [DiskCleanBadge] {
        var badges: [DiskCleanBadge] = []

        if let outcome {
            badges.append(contentsOf: self.badges(for: outcome, localization: localization))
        }

        // Candidate-local facts (P2 repo status, installer age) come before safety status:
        // they explain "why this item was not selected by default"—the first question users ask when something is unchecked.
        badges += candidate.notes.compactMap { badge(for: $0, localization: localization) }

        switch candidate.safety {
        case .allowed:
            break
        case let .inUse(processName):
            badges.append(
                DiskCleanBadge(
                    id: "inUse",
                    text: localization.format("badge.inUse", defaultValue: "使用中：%@", processName),
                    tone: .warning
                )
            )
        case .whitelisted:
            badges.append(
                DiskCleanBadge(
                    id: "whitelisted",
                    text: localization.string("badge.whitelisted", defaultValue: "白名单"),
                    tone: .neutral
                )
            )
        case .protected:
            badges.append(
                DiskCleanBadge(
                    id: "protected",
                    text: localization.string("badge.protected", defaultValue: "受保护"),
                    tone: .neutral
                )
            )
        case .invalid:
            badges.append(
                DiskCleanBadge(
                    id: "invalid",
                    text: localization.string("badge.invalid", defaultValue: "路径不安全"),
                    tone: .neutral
                )
            )
        case .requiresAdmin:
            badges.append(
                DiskCleanBadge(
                    id: "requiresAdmin",
                    text: localization.string("badge.requiresAdmin", defaultValue: "需要管理员"),
                    tone: .neutral
                )
            )
        }

        guard let sizeResult = candidate.sizeResult else {
            badges.append(
                DiskCleanBadge(
                    id: "sizing",
                    text: localization.string("badge.sizing", defaultValue: "计算中"),
                    tone: .neutral
                )
            )
            return badges
        }

        let reasons = sizeResult.completeness.partialReasons
        // Mount points are listed separately: not "incomplete sizing", but "this directory contains another volume; deleting it would cross boundaries".
        if reasons.contains(.crossedMountPoint) {
            badges.append(
                DiskCleanBadge(
                    id: "crossedMountPoint",
                    text: localization.string("badge.crossedMountPoint", defaultValue: "含挂载点"),
                    tone: .warning
                )
            )
        }
        let otherReasons = reasons.subtracting([.crossedMountPoint])
        if !otherReasons.isEmpty {
            badges.append(
                DiskCleanBadge(
                    id: "partial",
                    text: localization.format(
                        "badge.partial",
                        defaultValue: "扫描不完整：%@",
                        DiskCleanFormat.partialReasons(otherReasons, localization: localization)
                    ),
                    tone: .warning
                )
            )
        }

        return badges
    }

    /// Candidate annotation badges (design §10 P2 badge system).
    ///
    /// "Owning project" is not a badge: it is **locating information**, not a warning; packing it into the capsule row would drown the real
    /// "uncommitted changes" signal. Project path is already expressed by the candidate path itself.
    private static func badge(
        for note: DiskCleanCandidateNote,
        localization: PluginLocalization
    ) -> DiskCleanBadge? {
        switch note {
        case let .repositoryHasChanges(_, reason):
            return DiskCleanBadge(
                id: "repositoryHasChanges",
                text: repositoryChangeText(reason, localization: localization),
                tone: .warning
            )
        case .mayNotBeInstaller:
            return DiskCleanBadge(
                id: "mayNotBeInstaller",
                text: localization.string("badge.mayNotBeInstaller", defaultValue: "未必是安装包"),
                tone: .neutral
            )
        case let .recentlyDownloaded(modifiedAt):
            return DiskCleanBadge(
                id: "recentlyDownloaded",
                text: localization.format(
                    "badge.recentlyDownloaded",
                    defaultValue: "近期下载：%@",
                    DiskCleanFormat.timestamp(modifiedAt)
                ),
                tone: .neutral
            )
        case .developerProject:
            return nil
        }
    }

    /// Treat check failure separately from real dirt: the former is "could not determine; treat as dirty", writing it as "has uncommitted changes"
    /// would invent a fact the user cannot find in the repo.
    private static func repositoryChangeText(
        _ reason: DiskCleanPurgeGitState.DirtyReason,
        localization: PluginLocalization
    ) -> String {
        switch reason {
        case .uncommittedChanges:
            return localization.string("badge.repository.uncommitted", defaultValue: "仓库有未提交改动")
        case .unpushedCommits:
            return localization.string("badge.repository.unpushed", defaultValue: "仓库有未推送提交")
        case let .inspectionFailed(detail):
            return localization.format(
                "badge.repository.inspectionFailed",
                defaultValue: "无法确认仓库状态：%@",
                detail
            )
        }
    }

    private static func badges(
        for outcome: DiskCleanExecutionItemResult.Outcome,
        localization: PluginLocalization
    ) -> [DiskCleanBadge] {
        switch outcome {
        case .changedSinceScan:
            return [
                DiskCleanBadge(
                    id: "changedSinceScan",
                    text: localization.string("badge.changedSinceScan", defaultValue: "内容已变化，请重新扫描"),
                    tone: .warning
                )
            ]
        case .partiallyDeleted:
            return [
                DiskCleanBadge(
                    id: "partiallyDeleted",
                    text: localization.string("badge.partiallyDeleted", defaultValue: "只删除了一部分"),
                    tone: .warning
                )
            ]
        case .rollbackBlocked:
            return [
                DiskCleanBadge(
                    id: "rollbackBlocked",
                    text: localization.string("badge.rollbackBlocked", defaultValue: "无法放回原处"),
                    tone: .warning
                )
            ]
        case let .failed(message):
            return [DiskCleanBadge(id: "failed", text: message, tone: .warning)]
        case .removed, .trashed, .skipped:
            return []
        }
    }
}

struct DiskCleanBadgeLabel: View {
    let badge: DiskCleanBadge

    var body: some View {
        Text(badge.text)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(badge.tone == .warning ? Color.orange : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            )
    }
}

// MARK: - Tri-state checkbox

/// Tri-state checkbox.
///
/// `Toggle` only has on/off, but category selection must express "partially selected"—categories that contain medium/high items
/// necessarily land in mixed after "select all low-risk"; a two-state control would keep showing "not fully selected"
/// and users would think they mis-clicked.
struct DiskCleanTriStateCheckbox: View {
    let state: DiskCleanCategorySelectionState
    let onToggle: () -> Void
    let help: String

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: symbolName)
                .font(.system(size: 14))
                .foregroundStyle(state.isChecked ? Color.accentColor : Color.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon, height: PluginSettingsTheme.Size.rowIcon)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var symbolName: String {
        switch state {
        case .allSelected:
            return "checkmark.square.fill"
        case .partiallySelected:
            return "minus.square.fill"
        case .noneSelected, .unavailable:
            return "square"
        }
    }
}
