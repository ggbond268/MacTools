import SwiftUI
import MacToolsPluginKit

// MARK: - History entry

/// Status of a cleanup history entry.
///
/// Domain matches the `status` strings written to the audit log (`DiskCleanExecutor.status(of:)` and
/// `DiskCleanStagingReconciler.record(for:)`). Parse rather than display the raw string because
/// "which statuses need a pinned alert" is a product decision that needs a single home.
enum DiskCleanCleanupHistoryStatus: Equatable, Sendable {
    case ok
    case skipped
    case changedSinceScan
    case failed
    case partiallyDeleted
    case rollbackBlocked
    case reconciledRolledBack
    case reconciledAbsent
    case reconcileFailed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "ok":
            self = .ok
        case "skipped":
            self = .skipped
        case "changedSinceScan":
            self = .changedSinceScan
        case "failed":
            self = .failed
        case "partiallyDeleted":
            self = .partiallyDeleted
        case "rollbackBlocked":
            self = .rollbackBlocked
        case "reconciledRolledBack":
            self = .reconciledRolledBack
        // A missing parent directory and a missing staged object reach the same conclusion: nothing left to restore.
        case "reconciledAbsent", "reconciledParentMissing":
            self = .reconciledAbsent
        case "reconcileFailed":
            self = .reconcileFailed
        default:
            self = .unknown(rawValue)
        }
    }

    /// Honest terminal statuses that need a pinned alert (design §7.5, §13-M4-6).
    ///
    /// What they share: the disk still holds a staged object the user may not know about, or a deletion only finished halfway.
    /// Ordinary `failed`/`skipped` leave no residue and need not interrupt the user.
    var needsAttention: Bool {
        switch self {
        case .partiallyDeleted, .rollbackBlocked, .reconcileFailed:
            return true
        case .ok, .skipped, .changedSinceScan, .failed,
             .reconciledRolledBack, .reconciledAbsent, .unknown:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .skipped, .changedSinceScan:
            return "minus.circle"
        case .failed:
            return "xmark.circle"
        case .partiallyDeleted, .rollbackBlocked, .reconcileFailed:
            return "exclamationmark.triangle.fill"
        case .reconciledRolledBack:
            return "arrow.uturn.backward.circle"
        case .reconciledAbsent:
            return "circle"
        case .unknown:
            return "circle"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .ok:
            return localization.string("history.status.ok", defaultValue: "已清理")
        case .skipped:
            return localization.string("history.status.skipped", defaultValue: "已跳过")
        case .changedSinceScan:
            return localization.string("history.status.changed", defaultValue: "内容已变化")
        case .failed:
            return localization.string("history.status.failed", defaultValue: "失败")
        case .partiallyDeleted:
            return localization.string("history.status.partiallyDeleted", defaultValue: "只删除了一部分")
        case .rollbackBlocked:
            return localization.string("history.status.rollbackBlocked", defaultValue: "无法放回原处")
        case .reconciledRolledBack:
            return localization.string("history.status.reconciledRolledBack", defaultValue: "启动时已放回")
        case .reconciledAbsent:
            return localization.string("history.status.reconciledAbsent", defaultValue: "上次已完成")
        case .reconcileFailed:
            return localization.string("history.status.reconcileFailed", defaultValue: "未完成，待处理")
        case let .unknown(rawValue):
            return rawValue
        }
    }
}

/// One cleanup history row. A display projection of an audit record.
struct DiskCleanCleanupHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Date
    let status: DiskCleanCleanupHistoryStatus
    let path: String?
    /// Staged name. In Trash mode, "Put Back" lands under this name, so it must be shown (design §7.4).
    let stagedName: String?
    let estimatedBytes: Int64?
    let errorMessage: String?

    var needsAttention: Bool { status.needsAttention }

    /// Audit record → display entry. **Attention-needed rows are pinned** (design §13-M4-6); the rest stay reverse-chronological.
    ///
    /// Pin rather than only tint red: `partiallyDeleted` / `rollbackBlocked` mean residue remains on disk;
    /// burying them among 200 history rows is the same as not saying it.
    static func entries(from records: [DiskCleanAuditLog.Record]) -> [DiskCleanCleanupHistoryEntry] {
        let entries = records.enumerated().map { index, record in
            DiskCleanCleanupHistoryEntry(
                id: index,
                timestamp: record.timestamp,
                status: DiskCleanCleanupHistoryStatus(rawValue: record.status),
                path: record.path,
                stagedName: record.stagedName,
                estimatedBytes: record.estimatedBytes,
                errorMessage: record.error
            )
        }
        return entries.filter(\.needsAttention) + entries.filter { !$0.needsAttention }
    }
}

// MARK: - Loading

/// Read seam for cleanup history. The audit log is on disk; loading must not block the main thread.
protocol DiskCleanCleanupHistoryProviding: Sendable {
    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry]
    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry]
}

extension DiskCleanCleanupHistoryProviding {
    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry] {
        []
    }
}

struct DiskCleanAuditLogHistoryProvider: DiskCleanCleanupHistoryProviding {
    let directory: URL

    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry] {
        let directory = directory
        let records = await Task.detached(priority: .utility) {
            DiskCleanAuditLog(directory: directory).recentRecords(limit: limit)
        }.value
        return DiskCleanCleanupHistoryEntry.entries(from: records)
    }

    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry] {
        let directory = directory
        return await Task.detached(priority: .utility) {
            DiskCleanAuditLog(directory: directory).recentRuns(limit: limit)
        }.value
    }
}

// MARK: - View

/// Cleanup history section. Load from disk only when expanded—rescanning the log every time settings appear is unnecessary.
struct DiskCleanCleanupHistorySection: View {
    let provider: any DiskCleanCleanupHistoryProviding
    let localization: PluginLocalization

    private static let recordLimit = 100

    enum HistoryViewMode: String, CaseIterable, Identifiable {
        case runs
        case items

        var id: String { rawValue }
    }

    @State private var isExpanded = false
    @State private var entries: [DiskCleanCleanupHistoryEntry] = []
    @State private var runs: [DiskCleanRunHistoryEntry] = []
    @State private var isLoading = false
    @State private var viewMode: HistoryViewMode = .runs
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
                    .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
            } label: {
                Text(localization.string("detail.history.title", defaultValue: "清理历史"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await loadData()
        }
    }

    private func loadData() async {
        isLoading = true
        async let loadedEntries = provider.recentEntries(limit: Self.recordLimit)
        async let loadedRuns = provider.recentRuns(limit: Self.recordLimit)
        entries = await loadedEntries
        runs = await loadedRuns
        isLoading = false
    }

    private var reloadButton: some View {
        Button {
            Task { await loadData() }
        } label: {
            Label(
                localization.string("detail.history.reload", defaultValue: "刷新"),
                systemImage: "arrow.clockwise"
            )
            .font(PluginSettingsTheme.Typography.controlLabel)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isLoading)
    }

    private var copyDiagnosticsButton: some View {
        Button {
            copyDiagnostics()
            isCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isCopied = false
            }
        } label: {
            Label(
                isCopied
                    ? localization.string("detail.history.copied", defaultValue: "已复制")
                    : localization.string("detail.history.copyDiagnostics", defaultValue: "复制诊断"),
                systemImage: isCopied ? "checkmark" : "doc.on.doc"
            )
            .font(PluginSettingsTheme.Typography.controlLabel)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isLoading || (entries.isEmpty && runs.isEmpty))
    }

    private func copyDiagnostics() {
        let home = NSHomeDirectory()
        var lines: [String] = ["=== DiskClean Cleanup History Diagnostics ==="]
        for run in runs {
            let mode = run.isTrash ? "Trash" : "Permanent"
            lines.append("Run [\(DiskCleanFormat.timestamp(run.timestamp))] Status: \(run.status), Mode: \(mode), Removed: \(run.itemsRemoved) items (\(run.bytesRemoved) bytes), Categories: \(run.categoriesCleaned.joined(separator: ", "))")
            for error in run.errorsEncountered {
                lines.append("  Error: \(error.replacingOccurrences(of: home, with: "~"))")
            }
        }
        lines.append("\n=== Recent Items ===")
        for entry in entries.prefix(50) {
            let path = (entry.path ?? "nil").replacingOccurrences(of: home, with: "~")
            lines.append("[\(entry.timestamp)] \(path) - Status: \(entry.status.symbolName) - \(entry.estimatedBytes ?? 0) bytes")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                ProgressView().controlSize(.small)
                Text(localization.string("detail.history.loading", defaultValue: "正在读取记录…"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .pluginSettingsListRowPadding()
        } else if entries.isEmpty && runs.isEmpty {
            Text(localization.string("detail.history.empty", defaultValue: "还没有清理记录"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsListRowPadding()
                .pluginSettingsCardBackground(.standard)
        } else {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                if let attentionCount {
                    attentionBanner(count: attentionCount)
                }

                HStack {
                    Picker("", selection: $viewMode) {
                        Text(localization.format("detail.history.view.runs", defaultValue: "按次汇总 (%d)", runs.count))
                            .tag(HistoryViewMode.runs)
                        Text(localization.format("detail.history.view.items", defaultValue: "全部明细 (%d)", entries.count))
                            .tag(HistoryViewMode.items)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(maxWidth: 240)

                    Spacer()

                    copyDiagnosticsButton
                    reloadButton
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewMode == .runs {
                            ForEach(runs) { run in
                                DiskCleanRunHistoryRow(run: run, localization: localization)
                                if run.id != runs.last?.id {
                                    PluginSettingsListDivider()
                                }
                            }
                        } else {
                            ForEach(entries) { entry in
                                DiskCleanCleanupHistoryRow(entry: entry, localization: localization)
                                if entry.id != entries.last?.id {
                                    PluginSettingsListDivider()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .pluginSettingsCardBackground(.standard)
            }
        }
    }

    private var attentionCount: Int? {
        let count = entries.filter(\.needsAttention).count
        return count > 0 ? count : nil
    }

    private func attentionBanner(count: Int) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(
                    localization.format(
                        "detail.history.attention.title",
                        defaultValue: "有 %d 项清理未完成",
                        count
                    )
                )
                .font(PluginSettingsTheme.Typography.rowTitle)

                Text(
                    localization.string(
                        "detail.history.attention.description",
                        defaultValue: "这些项目在磁盘上留下了以 .mactools-staged- 开头的暂存对象，可在下方记录里查看原路径后自行处理。"
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .pluginSettingsListRowPadding()
        .pluginSettingsCardBackground(.standard)
    }
}

private struct DiskCleanCleanupHistoryRow: View {
    let entry: DiskCleanCleanupHistoryEntry
    let localization: PluginLocalization

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: entry.status.symbolName)
                .foregroundStyle(entry.needsAttention ? Color.orange : Color.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(entry.status.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Text(DiskCleanFormat.timestamp(entry.timestamp))
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }

                if let path = entry.path {
                    Text(path)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                // Objects in Trash land under the staged name; without showing it the user cannot find them (design §7.4).
                if let stagedName = entry.stagedName {
                    Text(
                        localization.format(
                            "detail.history.stagedName",
                            defaultValue: "暂存名：%@",
                            stagedName
                        )
                    )
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }

                if let errorMessage = entry.errorMessage {
                    Text(errorMessage)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let bytes = entry.estimatedBytes {
                Text(DiskCleanFormat.approximateBytes(bytes, localization: localization))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(width: DiskCleanFormat.byteColumnWidth, alignment: .trailing)
            }
        }
        .pluginSettingsListRowPadding()
    }
}


private struct DiskCleanRunHistoryRow: View {
    let run: DiskCleanRunHistoryEntry
    let localization: PluginLocalization

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: run.needsAttention ? "exclamationmark.triangle.fill" : (run.isTrash ? "trash" : "checkmark.circle.fill"))
                    .foregroundStyle(run.needsAttention ? Color.orange : (run.isTrash ? Color.secondary : Color.green))
                    .frame(width: PluginSettingsTheme.Size.rowIcon)

                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        Text(DiskCleanFormat.timestamp(run.timestamp))
                            .font(PluginSettingsTheme.Typography.rowTitle)

                        Text(run.isTrash
                            ? localization.string("detail.history.mode.trash", defaultValue: "废纸篓")
                            : localization.string("detail.history.mode.permanent", defaultValue: "永久删除"))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4)))

                        if run.needsAttention {
                            Text(localization.string("detail.history.attentionBadge", defaultValue: "需关注"))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                        }

                        Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                        Text(DiskCleanFormat.approximateBytes(run.bytesRemoved, localization: localization))
                            .font(PluginSettingsTheme.Typography.monospacedValue)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        Text(localization.format("detail.history.runItems", defaultValue: "清理 %d 项", run.itemsRemoved))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)

                        if !run.categoriesCleaned.isEmpty {
                            Text("·")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(run.categoriesCleaned.joined(separator: ", "))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    if !run.errorsEncountered.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(run.errorsEncountered.prefix(2).enumerated()), id: \.offset) { _, err in
                                Text(err)
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if !run.itemEntries.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(PluginSettingsTheme.Typography.rowIcon)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .pluginSettingsListRowPadding()

            if isExpanded && !run.itemEntries.isEmpty {
                VStack(spacing: 0) {
                    PluginSettingsListDivider()
                    ForEach(run.itemEntries) { entry in
                        DiskCleanCleanupHistoryRow(entry: entry, localization: localization)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }
}
