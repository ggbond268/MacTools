import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

/// At most one main-actor delivery is queued regardless of archive record count.
private final class ClipboardBackupProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ClipboardBackupPhase?
    private var pending = false
    private let deliver: @MainActor @Sendable (ClipboardBackupPhase) -> Void

    init(deliver: @escaping @MainActor @Sendable (ClipboardBackupPhase) -> Void) { self.deliver = deliver }

    func submit(_ phase: ClipboardBackupPhase) {
        let schedule = lock.withLock {
            latest = phase
            if pending { return false }
            pending = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in
            let phase = lock.withLock {
                defer { latest = nil; pending = false }
                return latest
            }
            if let phase { deliver(phase) }
        }
    }
}

@MainActor
final class ClipboardBackupPresentation: ObservableObject {
    @Published var phase: ClipboardBackupPhase?
    @Published var preview: ClipboardBackupPreview?
    @Published var result: ClipboardBackupSummary?
    @Published var error: String?
    @Published var completed = false
    var localization: PluginLocalization?
    private var operationGeneration = 0
    private var work: Task<Void, Never>?
    private(set) var didRestore = false
    var isBusy: Bool { work != nil }
    var isFinishing: Bool { if case .finishing = phase { true } else { false } }

    func close(resume: @escaping (Bool) -> Void) {
        cancel()
        let pending = work
        Task { await pending?.value; resume(didRestore) }
    }

    func cancel() { if !isFinishing { work?.cancel() } }

    func run<Result: Sendable>(
        operation: @escaping @Sendable (@escaping @Sendable (ClipboardBackupPhase) -> Void) throws -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        guard work == nil else { return }
        error = nil
        operationGeneration += 1
        let generation = operationGeneration
        phase = .reading
        work = Task { [weak self] in
            guard let self else { return }
            let relay = ClipboardBackupProgressRelay { [weak self] phase in
                guard let self, self.operationGeneration == generation, self.work != nil else { return }
                self.phase = phase
            }
            let worker = Task.detached(priority: .userInitiated) {
                try operation { phase in relay.submit(phase) }
            }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                completion(value)
            } catch is CancellationError {
                // The pre-commit worker owns and removes temporary files.
            } catch {
                self.error = message(error)
            }
            phase = nil
            work = nil
        }
    }

    private func message(_ error: Error) -> String {
        guard let localization else { return ClipboardBackupError.storage.errorDescription ?? "" }
        switch error as? ClipboardBackupError {
        case .invalidArchive: return localization.string("backup.error.invalid", defaultValue: "备份无效、已损坏或密码错误。当前数据未更改。")
        case .unsupportedVersion: return localization.string("backup.error.version", defaultValue: "此备份版本暂不受支持。")
        case .invalidPassword: return localization.string("backup.error.password", defaultValue: "请输入 12 至 1,024 字节的备份密码。MacTools 无法找回密码。")
        case .limitExceeded: return localization.string("backup.error.limit", defaultValue: "备份超过安全上限或当前单项大小限制。")
        case .changedSincePreview: return localization.string("backup.error.changed", defaultValue: "本机剪贴板数据已更改。请重新预览备份。")
        default: return localization.string("backup.error.storage", defaultValue: "无法读写备份。请检查可用磁盘空间和文件权限。")
        }
    }

    func restored(_ summary: ClipboardBackupSummary) {
        didRestore = true
        completed = true
        result = summary
    }
}

@MainActor
struct ClipboardBackupRegion: View {
    let localization: PluginLocalization
    let controller: ClipboardHistoryController
    let makeService: () -> ClipboardBackupService?
    let suspend: () -> Void
    let resume: (Bool) -> Void
    @State private var action: Action?
    enum Action: String, Identifiable { case backup, restore, rollback; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Label(localization.string("backup.title", defaultValue: "剪贴板备份"), systemImage: "externaldrive.badge.timemachine")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            HStack {
                Button(localization.string("backup.create", defaultValue: "备份剪贴板数据…")) { action = .backup }
                Button(localization.string("backup.restore", defaultValue: "恢复剪贴板备份…")) { action = .restore }
            }
            if let service = makeService(), FileManager.default.fileExists(atPath: service.rollbackURL.path) {
                Button(localization.string("backup.rollback", defaultValue: "恢复本机回滚快照…")) { action = .rollback }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .pluginSettingsListRowPadding(interactive: true)
        .sheet(item: $action) { action in
            if let service = makeService() {
                ClipboardBackupSheet(action: action, service: service, localization: localization,
                                     historyCount: controller.items.filter(\.isInHistory).count,
                                     historyBytes: controller.items.filter(\.isInHistory).reduce(0) { $0 + $1.payloadByteCount },
                                     suspend: suspend, resume: resume)
            }
        }
    }
}

@MainActor
struct ClipboardBackupSheet: View {
    let action: ClipboardBackupRegion.Action
    let service: ClipboardBackupService
    let localization: PluginLocalization
    let historyCount: Int
    let historyBytes: Int
    let suspend: () -> Void
    let resume: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ClipboardBackupPresentation()
    @State private var scope = ClipboardBackupScope()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var sourceURL: URL?
    @State private var replacing = false
    @State private var confirmsReplacement = false
    @State private var missingOffset = 0
    @State private var missingPaths: [String] = []
    @State private var noticeOffset = 0
    @State private var notices: [ClipboardBackupNotice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Text(localization.string("backup.title", defaultValue: "剪贴板备份"))
                .font(PluginSettingsTheme.Typography.pageTitle)
            if model.completed {
                Label(localization.string("backup.completed", defaultValue: "备份操作已完成"), systemImage: "checkmark.circle")
                if let result = model.result { summary(result) }
            } else {
                if action == .backup { scopeControls }
                if action != .rollback && model.preview == nil {
                    SecureField(localization.string("backup.password", defaultValue: "备份密码"), text: $password)
                        .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                    if action == .backup {
                        SecureField(localization.string("backup.confirmPassword", defaultValue: "再次输入密码"), text: $confirmation)
                            .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                    }
                    Text(localization.string("backup.passwordWarning", defaultValue: "至少 12 字节。密码不会保存；MacTools 无法找回遗忘的密码。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                if action == .restore {
                    Button(localization.string("backup.choose", defaultValue: "选择备份文件…")) { chooseSource() }.disabled(model.isBusy)
                    if let sourceURL { Text(sourceURL.lastPathComponent).lineLimit(1).textSelection(.enabled) }
                }
                if action != .backup {
                    Toggle(localization.string("backup.replaceChoice", defaultValue: "替换备份中包含的类别（破坏性操作）"), isOn: $replacing)
                        .toggleStyle(.switch)
                        .disabled(action == .rollback || model.isBusy)
                        .onChange(of: replacing) { _, _ in model.preview = nil }
                    if !replacing { Text(localization.string("backup.merge", defaultValue: "与本机合并（推荐）")) }
                    if let preview = model.preview {
                        Text(preview.manifest.createdAt, style: .date)
                        Text(localization.format("backup.manifest", defaultValue: "版本 %d · 历史 %d · 已存 %d · 片段 %d", preview.manifest.version, preview.manifest.history, preview.manifest.saved, preview.manifest.snippets))
                        Text(ByteCountFormatter.string(fromByteCount: preview.manifest.payloadBytes, countStyle: .file))
                        Text(categoryTitle(preview.manifest.scope))
                        summary(preview.summary)
                        if preview.replacement {
                            Text(localization.format("backup.removed", defaultValue: "将移除 %d 个本机项目的所选类别数据。提交前会创建本机加密回滚快照。", preview.summary.removed))
                        }
                    }
                }
            }
            if let preview = model.preview, preview.summary.missingFileReferences > 0 {
                DisclosureGroup(localization.string("backup.missingPaths", defaultValue: "失效的外部文件路径")) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(missingPaths.enumerated()), id: \.offset) { _, path in Text(path).textSelection(.enabled) }
                        }
                    }.frame(maxHeight: 120)
                    HStack {
                        Button(localization.string("backup.previous", defaultValue: "上一页")) { missingOffset = max(0, missingOffset - 50); loadMissingPaths() }
                            .disabled(missingOffset == 0 || model.isBusy)
                        Text("\(missingOffset + 1)–\(min(missingOffset + 50, preview.summary.missingFileReferences)) / \(preview.summary.missingFileReferences)")
                        Button(localization.string("backup.next", defaultValue: "下一页")) { missingOffset += 50; loadMissingPaths() }
                            .disabled(missingOffset + 50 >= preview.summary.missingFileReferences || model.isBusy)
                    }
                }.font(PluginSettingsTheme.Typography.rowDescription)
            }
            if let preview = model.preview, preview.summary.conflicts + preview.summary.disabledKeywords > 0 {
                DisclosureGroup(localization.string("backup.conflictDetails", defaultValue: "需处理的冲突")) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                                if notice.kind == .disabledKeyword {
                                    Text("\(notice.title ?? notice.id.uuidString) · \(notice.keyword ?? "")")
                                } else { Text("\(notice.originalID.uuidString) → \(notice.id.uuidString)") }
                            }
                        }.textSelection(.enabled)
                    }.frame(maxHeight: 100)
                    HStack {
                        Button(localization.string("backup.previous", defaultValue: "上一页")) { noticeOffset = max(0, noticeOffset - 50); loadNotices() }
                            .disabled(noticeOffset == 0 || model.isBusy)
                        Spacer()
                        Button(localization.string("backup.next", defaultValue: "下一页")) { noticeOffset += 50; loadNotices() }
                            .disabled(noticeOffset + 50 >= preview.summary.conflicts + preview.summary.disabledKeywords || model.isBusy)
                    }
                }.font(PluginSettingsTheme.Typography.rowDescription)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let phase = model.phase {
                HStack {
                    if case let .staging(done, total) = phase, total > 0 {
                        ProgressView(value: Double(done), total: Double(total)).frame(width: 140)
                    } else { ProgressView().controlSize(.small) }
                    Text(phaseText(phase))
                }
                    .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button(localization.string("common.cancel", defaultValue: "取消")) {
                    if model.isBusy { model.cancel() } else { password = ""; confirmation = ""; dismiss() }
                }.disabled(model.isFinishing)
                if model.completed {
                    Button(localization.string("backup.done", defaultValue: "完成")) { dismiss() }
                } else {
                    Button(primaryTitle) { primaryAction() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || !canProceed)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowTitle)
        .buttonStyle(.bordered).controlSize(.small)
        .frame(width: 540).padding(24)
        .disabled(model.isBusy && model.isFinishing)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { model.localization = localization; suspend(); if action == .rollback { replacing = true } }
        .onDisappear { password = ""; confirmation = ""; model.close(resume: resume) }
        .confirmationDialog(primaryTitle, isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button(primaryTitle, role: .destructive) { commit() }
        } message: {
            Text(localization.format("backup.removed", defaultValue: "将移除 %d 个本机项目的所选类别数据。提交前会创建本机加密回滚快照。", model.preview?.summary.removed ?? 0))
        }
    }

    private var scopeControls: some View {
        VStack(alignment: .leading) {
            Toggle(localization.string("backup.saved", defaultValue: "已存项目"), isOn: $scope.saved)
            Toggle(localization.string("backup.snippets", defaultValue: "片段"), isOn: $scope.snippets)
            Toggle(localization.string("backup.history", defaultValue: "历史记录"), isOn: $scope.history)
            Text("\(historyCount) · \(ByteCountFormatter.string(fromByteCount: Int64(historyBytes), countStyle: .file))")
            Text(localization.string("backup.historyWarning", defaultValue: "历史记录可能包含敏感信息。仅在明确需要时加入备份。外部文件仅保存路径。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        }.toggleStyle(.switch).disabled(model.isBusy)
    }

    private var canProceed: Bool {
        if model.preview != nil { return true }
        if action == .rollback { return true }
        if action == .backup { return !scope.isEmpty && password.utf8.count >= 12 && password.utf8.count <= 1_024 && password == confirmation }
        return sourceURL != nil && !password.isEmpty && password.utf8.count <= 1_024
    }

    private var primaryTitle: String {
        if let preview = model.preview {
            return preview.replacement ? replacementTitle(preview.manifest.scope) : localization.string("backup.merge", defaultValue: "与本机合并（推荐）")
        }
        return action == .backup ? localization.string("backup.create", defaultValue: "备份剪贴板数据…")
            : localization.string("backup.preview", defaultValue: "验证并预览")
    }

    private func categoryTitle(_ scope: ClipboardBackupScope) -> String {
        [scope.history ? localization.string("backup.history", defaultValue: "历史记录") : nil,
         scope.saved ? localization.string("backup.saved", defaultValue: "已存项目") : nil,
         scope.snippets ? localization.string("backup.snippets", defaultValue: "片段") : nil].compactMap { $0 }.joined(separator: " + ")
    }

    private func replacementTitle(_ scope: ClipboardBackupScope) -> String {
        if scope.isComplete { return localization.string("backup.replaceAll", defaultValue: "替换全部剪贴板数据") }
        return localization.format("backup.replaceScope", defaultValue: "替换 %@", categoryTitle(scope))
    }

    private func summary(_ value: ClipboardBackupSummary) -> some View {
        Text(localization.format("backup.summary", defaultValue: "新增 %d · 合并 %d · 冲突保留 %d · 跳过 %d · 停用关键词 %d · 文件路径失效 %d", value.added, value.merged, value.conflicts, value.skipped, value.disabledKeywords, value.missingFileReferences))
            .font(PluginSettingsTheme.Typography.rowDescription).textSelection(.enabled)
    }

    private func phaseText(_ phase: ClipboardBackupPhase) -> String {
        switch phase {
        case .reading: localization.string("backup.reading", defaultValue: "正在读取并派生密钥…")
        case .encrypting(let count): localization.format("backup.encrypting", defaultValue: "正在加密：%d 项", count)
        case .validating(let count): localization.format("backup.validating", defaultValue: "正在验证：%d 项", count)
        case .staging(let count, _): localization.format("backup.staging", defaultValue: "正在暂存：%d 项", count)
        case .finishing: localization.string("backup.finishing", defaultValue: "正在完成…")
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mactoolsclipboard") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()
        if panel.runModal() == .OK { sourceURL = panel.url; model.preview = nil }
    }

    private func primaryAction() {
        if let preview = model.preview {
            if preview.replacement { confirmsReplacement = true } else { commit() }
            return
        }
        let service = service
        if action == .backup {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "mactoolsclipboard") ?? .data]
            panel.nameFieldStringValue = "Clipboard.mactoolsclipboard"
            PluginPresentationSafety.prepareForWindowOrdering()
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            let url = selected.pathExtension.lowercased() == "mactoolsclipboard" ? selected : selected.appendingPathExtension("mactoolsclipboard")
            let password = password, scope = scope
            model.run(operation: { progress in try service.backUp(to: url, password: password, scope: scope, progress: progress) }) { _ in
                self.password = ""; confirmation = ""; model.completed = true
            }
        } else if action == .rollback {
            model.run(operation: { progress in try service.previewRollback(progress: progress) }) { model.preview = $0; missingOffset = 0; noticeOffset = 0; loadMissingPaths(); loadNotices() }
        } else if let sourceURL {
            let password = password, replacing = replacing
            model.run(operation: { progress in try service.preview(url: sourceURL, password: password, replacing: replacing, progress: progress) }) {
                model.preview = $0; missingOffset = 0; noticeOffset = 0; loadMissingPaths(); loadNotices()
            }
        }
    }

    private func loadMissingPaths() {
        guard let preview = model.preview else { return }
        let service = service, offset = missingOffset
        Task {
            let worker = Task.detached { try service.missingReferences(preview, offset: offset) }
            missingPaths = (try? await worker.value) ?? []
        }
    }

    private func loadNotices() {
        guard let preview = model.preview else { return }
        let service = service, offset = noticeOffset
        Task {
            let worker = Task.detached { try service.notices(preview, offset: offset) }
            notices = (try? await worker.value) ?? []
        }
    }

    private func commit() {
        guard let preview = model.preview else { return }
        let service = service
        model.run(operation: { progress in try service.commit(preview, progress: progress); return preview.summary }) {
            password = ""; confirmation = ""; model.restored($0)
        }
    }
}
