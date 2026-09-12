import AppKit
import QuickLookUI
import SwiftUI
import MacToolsPluginKit

struct AppUninstallerView: View {
    @ObservedObject var controller: AppUninstallerController
    let localization: PluginLocalization
    @State private var showsBrowser = false
    @State private var search = ""
    @State private var previewURL: URL?
    @State private var confirmsSource = false
    @State private var showsForceQuit = false

    private func l(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: 12) {
                Label(l("review.reviewFirst", "先检查，再确认移入废纸篓"), systemImage: "eye")
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(l("review.drop", "拖入一个应用，或选择应用以检查关联文件。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                HStack {
                    Button(l("review.choose", "选择应用…"), action: controller.choose)
                    Button(l("review.installed", "浏览已安装应用…")) { showsBrowser = true; controller.browse() }
                    if controller.selectedPath != nil {
                        Button(l("review.rescan", "重新扫描"), action: controller.rescan).disabled(controller.isScanning)
                    }
                    if controller.isScanning || controller.isBrowsing {
                        Button(l("review.cancel", "取消扫描"), action: controller.cancel)
                    }
                }.buttonStyle(.bordered).controlSize(.small).disabled(controller.isRemoving)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).pluginSettingsCardBackground(.standard)
            if controller.isScanning {
                HStack { ProgressView().controlSize(.small); Text(l("review.scanning", "正在检查应用身份与关联位置…")) }
            }
            if controller.isRemoving {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(l("review.removing", "正在复核并移入废纸篓…"))
                    Button(l("review.stop", "停止"), action: controller.cancel)
                }
            }
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let scan = controller.scan {
                application(scan.application)
                coverage(scan)
                ForEach(UninstallConfidence.allCases, id: \.self) { confidence in
                    let items = scan.candidates.filter { $0.confidence == confidence }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                            Label(confidenceTitle(confidence), systemImage: confidence == .protected ? "lock.shield" : "doc.text.magnifyingglass")
                                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                            ForEach(items) { item in candidate(item) }
                        }
                    }
                }
                Text(l("review.scope", "仅检查列出的用户资料库位置及已读取的应用元数据。未搜索文稿、项目文件或全盘遗留文件；没有发现关联项不代表应用没有其他数据。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Button(l("review.plan", "检查移除清单…")) { confirmsSource = false; controller.preparePlan() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!scan.canPlan || controller.selectedIDs.isEmpty || context.date >= scan.expiresAt)
                }
            }
            history
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL, url.pathExtension.lowercased() == "app" else { return false }
            controller.review(url); return true
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL {
                VStack {
                    UninstallQuickLookView(url: previewURL).frame(width: 520, height: 360)
                    Button(l("browser.done", "完成")) { self.previewURL = nil }.keyboardShortcut(.cancelAction)
                }.padding(16)
            }
        }
        .sheet(isPresented: $showsBrowser) { browser }
        .sheet(item: $controller.pendingPlan) { plan in confirmation(plan) }
        .onDisappear { controller.cancel() }
    }

    private func application(_ app: UninstallApplication) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(PluginSettingsTheme.Typography.emphasizedRowTitle).lineLimit(2)
                    Text(app.bundleID).font(PluginSettingsTheme.Typography.rowDescription).textSelection(.enabled)
                    Text("\(app.version) (\(app.build))").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(controller.processCheckIncomplete ? l("app.stateUnknown", "运行状态待确认")
                     : controller.isRunning ? l("app.running", "正在运行") : l("app.notRunning", "未在运行"))
                    .font(PluginSettingsTheme.Typography.statusBadge)
            }
            Text(app.path).font(PluginSettingsTheme.Typography.rowDescription).textSelection(.enabled).lineLimit(3)
            Text(sourceTitle(app.source)).font(PluginSettingsTheme.Typography.rowDescription)
            if app.source == .homebrew {
                Button(l("app.homebrew", "在 Homebrew 中管理")) { controller.openHomebrew?() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            ForEach(app.vendorUninstallers, id: \.self) { path in
                Button(l("app.vendorTool", "在访达中查看厂商卸载工具") + " · " + URL(fileURLWithPath: path).lastPathComponent) {
                    controller.reveal(path)
                }.buttonStyle(.bordered).controlSize(.small)
            }
            Text(l("app.team", "签名团队：") + (app.teamID ?? l("app.signatureUnknown", "未验证或未签名")))
                .font(PluginSettingsTheme.Typography.rowDescription).textSelection(.enabled)
            ForEach(Array(app.restrictions.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle").font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
            HStack {
                Button(l("review.reveal", "在访达中显示")) { controller.reveal(app.path) }
                Button(l("review.preview", "快速查看应用")) {
                    guard (try? UninstallFileSystem().identity(at: app.path)) == app.identity else { controller.rescan(); return }
                    previewURL = URL(fileURLWithPath: app.path)
                }
                if controller.isMainAppRunning {
                    Button(l("app.quit", "退出应用")) { controller.quit(app) }.disabled(controller.isQuitting)
                }
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).pluginSettingsCardBackground(.standard)
    }

    private func coverage(_ scan: UninstallScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(l("coverage.title", "扫描范围与时效"), systemImage: "checklist")
                .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(l("coverage.observed", "检查时间：")); Text(scan.observedAt, style: .relative) }
                    if context.date >= scan.expiresAt {
                        Text(l("coverage.stale", "结果已过期。请重新扫描以查看当前状态。"))
                            .foregroundStyle(.orange)
                    }
                }.font(PluginSettingsTheme.Typography.rowDescription)
            }
            Text(scan.coverage.contains { $0.issue != nil }
                 ? l("coverage.partial", "部分检查未完成。未能读取的位置不代表没有关联文件。")
                 : l("coverage.complete", "已完成列出位置的检查。其他位置未检查。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
            DisclosureGroup(l("coverage.details", "查看检查位置与限制")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(scan.coverage.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path).textSelection(.enabled).lineLimit(3)
                            Text(entry.issue ?? l("coverage.checked", "已检查或位置不存在"))
                                .foregroundStyle(entry.issue == nil ? Color.secondary : .orange)
                        }
                    }
                    Text(l("coverage.installation", "安装来源仅检查 App Store 收据与常用 Homebrew 安装位置。自定义包管理器、全部厂商卸载程序及所有管理方式尚未验证。"))
                }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 8)
            }
            if scan.coverage.contains(where: { $0.issue != nil }) {
                Button(l("coverage.permission", "检查完全磁盘访问权限")) { controller.openFullDiskAccess?() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(16).pluginSettingsCardBackground(.standard)
    }

    private func candidate(_ item: UninstallCandidate) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(l("candidate.whyFound", "发现依据" )).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in Text(evidenceText(evidence)).textSelection(.enabled) }
                Text(l("candidate.consequence", "数据用途与可能损失")).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(consequence(item.dataClass))
                if let note = item.blockedReason { Label(note, systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
                HStack {
                    Button(l("review.reveal", "在访达中显示")) { controller.reveal(item.path) }
                    Button(l("review.copyPath", "拷贝路径")) { controller.copyPath(item.path) }
                }.buttonStyle(.bordered).controlSize(.small)
            }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 10)
        } label: {
            HStack(alignment: .top) {
                Toggle(isOn: Binding(get: { controller.selectedIDs.contains(item.id) },
                                     set: { controller.setSelected(item.id, selected: $0) })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden().disabled(!item.eligible)
                    .accessibilityLabel(l("candidate.select", "选择项目：") + item.path)
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(PluginSettingsTheme.Typography.rowTitle).lineLimit(2)
                    Text(kindTitle(item.dataClass)).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(item.snapshot.map { ByteCountFormatter.string(fromByteCount: $0.allocatedBytes, countStyle: .file) }
                     ?? l("candidate.incompleteSize", "大小未完整统计"))
                    .font(PluginSettingsTheme.Typography.monospacedValue).fixedSize()
            }
        }.padding(12).pluginSettingsCardBackground(.standard)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l("review.installed", "浏览已安装应用…")).font(.title2)
            TextField(l("browser.search", "搜索应用名称或标识符"), text: $search).textFieldStyle(.roundedBorder)
            if controller.isBrowsing { ProgressView() }
            if let inventory = controller.inventory {
                if !inventory.complete { Text(l("browser.partial", "应用列表不完整，部分位置无法读取。" )).foregroundStyle(.orange) }
                List(inventory.apps.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.bundleID.localizedStandardContains(search) }) { app in
                    Button {
                        showsBrowser = false; controller.review(URL(fileURLWithPath: app.path))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).lineLimit(1)
                            Text(app.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(app.name + ", " + app.path)
                }
            }
            if let error = controller.error { Text(error).foregroundStyle(.orange) }
            HStack { Spacer(); Button(l("browser.done", "完成")) { showsBrowser = false } }
        }.padding(20).frame(minWidth: 520, idealWidth: 640, minHeight: 440, idealHeight: 580)
    }

    private func confirmation(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l("plan.title", "确认移入废纸篓")).font(.title2)
            Text(plan.application.name + " · " + String(plan.items.count) + " · " + ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.path).textSelection(.enabled).font(.body)
                            Text(consequence(item.dataClass)).foregroundStyle(.secondary).font(.subheadline)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(minHeight: 120, maxHeight: 320)
            Text(l("plan.warning", "仅移入废纸篓，不会永久删除。放回应用不保证恢复所有状态。未选择的项目及未检查的位置会保留。"))
                .font(.subheadline).foregroundStyle(.secondary)
            if plan.application.source == .unknown {
                Toggle(l("plan.source", "我已确认此应用不是由包管理器管理，并已检查开发者的卸载说明。"), isOn: $confirmsSource)
                    .toggleStyle(.checkbox)
            }
            if controller.isMainAppRunning {
                HStack {
                    Text(l("app.mustQuit", "请先保存工作并退出应用。"))
                    Button(l("app.quit", "退出应用")) { controller.quit(plan.application) }.disabled(controller.isQuitting)
                    Button(l("app.forceQuit", "强制退出…")) { showsForceQuit = true }.disabled(controller.isQuitting)
                }
            }
            if controller.hasRunningHelpers {
                Text(l("app.helpers", "关联的后台进程仍在运行。请通过应用或厂商工具退出这些组件，然后重新检查。"))
                    .font(.subheadline).foregroundStyle(.orange)
            }
            if controller.processCheckIncomplete {
                Text(l("app.processUnknown", "部分运行进程无法识别，移除暂不可用。请稍后重新检查。"))
                    .font(.subheadline).foregroundStyle(.orange)
            }
            Button(l("app.recheck", "重新检查运行状态"), action: controller.refreshRunningState)
            if let error = controller.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button(l("plan.cancel", "取消")) { controller.pendingPlan = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(l("plan.trash", "移入废纸篓"), role: .destructive) { controller.removeReviewedPlan(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning || controller.processCheckIncomplete || controller.isQuitting || (plan.application.source == .unknown && !confirmsSource))
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 680)
            .alert(l("app.forceTitle", "强制退出可能丢失未保存的工作"), isPresented: $showsForceQuit) {
                Button(l("plan.cancel", "取消"), role: .cancel) { }
                Button(l("app.forceQuit", "强制退出…"), role: .destructive) { controller.quit(plan.application, force: true) }
            }
    }

    @ViewBuilder private var history: some View {
        if !controller.runs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(l("history.title", "移除记录"), systemImage: "clock.arrow.circlepath")
                        .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                    Spacer()
                    Button(l("history.clear", "清除已完成记录")) { controller.loadHistory(clear: true) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                ForEach(controller.runs) { run in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(l("history.estimated", "选中项目的估计大小：") + ByteCountFormatter.string(fromByteCount: run.estimatedBytes, countStyle: .file))
                            Text(l("history.space", "移入废纸篓不代表空间已释放。未测量实际回收空间。"))
                            ForEach(run.results) { result in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.originalPath).textSelection(.enabled)
                                    Text(dispositionTitle(result.disposition)).foregroundStyle(result.disposition == .trashed ? Color.secondary : .orange)
                                    if let message = result.message { Text(message).foregroundStyle(.secondary) }
                                    if let destination = result.destinationPath {
                                        Text(destination).textSelection(.enabled)
                                        Button(l("review.reveal", "在访达中显示")) { controller.reveal(destination) }
                                    } else if result.disposition != .trashed {
                                        Button(l("review.reveal", "在访达中显示")) { controller.reveal(result.originalPath) }
                                    }
                                }
                            }
                            Button(l("history.copy", "拷贝诊断信息（隐藏主目录）")) {
                                controller.copyPath(UninstallDiagnostics.redacted(run, home: NSHomeDirectory()))
                            }
                        }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 10).buttonStyle(.bordered).controlSize(.small)
                    } label: {
                        HStack {
                            Text(run.application.name)
                            Text(run.startedAt, style: .date).foregroundStyle(.secondary)
                            Spacer()
                            Text(run.complete ? l("history.completed", "所选项目已移入废纸篓") : l("history.partial", "未完成 · 请检查结果"))
                                .foregroundStyle(run.complete ? Color.secondary : .orange)
                        }
                    }.padding(12).pluginSettingsCardBackground(.standard)
                }
            }
        }
    }

    private func dispositionTitle(_ value: UninstallDisposition) -> String {
        switch value {
        case .trashed: l("result.trashed", "已移入废纸篓")
        case .retained: l("result.retained", "未选择，已保留")
        case .changed: l("result.changed", "已变化或过期，已保留")
        case .running: l("result.running", "仍在运行，已保留")
        case .blocked: l("result.blocked", "检查未通过，已保留")
        case .failed: l("result.failed", "移入失败，已恢复原位置")
        case .cancelled: l("result.cancelled", "已停止，项目保留原位")
        case .needsAttention: l("result.attention", "需要检查暂存位置")
        }
    }

    private func confidenceTitle(_ value: UninstallConfidence) -> String {
        switch value {
        case .verified: l("confidence.verified", "已验证标识")
        case .strong: l("confidence.strong", "精确标识匹配")
        case .shared: l("confidence.shared", "共享数据")
        case .possible: l("confidence.possible", "归属待核实")
        case .protected: l("confidence.protected", "冲突或受保护")
        }
    }
    private func kindTitle(_ value: UninstallDataClass) -> String {
        switch value {
        case .application: l("kind.application", "应用本体")
        case .cache: l("kind.cache", "缓存")
        case .log: l("kind.log", "日志")
        case .preference: l("kind.preference", "偏好设置")
        case .savedState: l("kind.savedState", "保存的应用状态")
        case .support: l("kind.support", "应用支持数据")
        case .container: l("kind.container", "应用容器")
        case .groupContainer: l("kind.groupContainer", "共享容器")
        case .launchAgent: l("kind.launchAgent", "启动代理")
        }
    }
    private func consequence(_ kind: UninstallDataClass) -> String {
        switch kind {
        case .application: l("loss.application", "应用的可执行文件与资源。关联数据可能保存在其他位置。")
        case .cache: l("loss.cache", "缓存可能用于离线访问；移除后可能需要重新下载或生成。")
        case .log: l("loss.log", "历史运行与诊断记录，移除后无法重新生成过去的记录。")
        case .preference: l("loss.preference", "应用偏好设置，可能包含账号或自定义配置。")
        case .savedState: l("loss.savedState", "保存的窗口与恢复状态，可能包含尚未恢复的工作。")
        case .support, .container: l("loss.sensitive", "可能包含数据库、聊天记录、模型或其他重要内容。归属明确不代表可以丢弃。")
        case .groupContainer: l("loss.shared", "多个应用可能共用此位置，不能仅根据一个应用确认独占归属。")
        case .launchAgent: l("loss.service", "可能管理后台服务；应使用开发者提供的管理方式。")
        }
    }
    private func sourceTitle(_ value: UninstallSource) -> String {
        switch value {
        case .unknown: l("source.unknown", "安装来源：未知")
        case .appStoreReceipt: l("source.receipt", "发现 App Store 收据（未验证购买记录）")
        case .homebrew: l("source.homebrew", "发现 Homebrew 安装记录，请使用 Homebrew 管理")
        case .system: l("source.system", "系统应用 · 受保护")
        case .managed: l("source.managed", "设备管理状态需要管理员确认")
        case .vendorRequired: l("source.vendor", "发现系统组件或可能的厂商卸载工具，请先查看说明")
        }
    }
    private func evidenceText(_ value: UninstallEvidence) -> String {
        switch value {
        case .selectedApplication: l("evidence.selected", "这是所选应用的有效应用包。")
        case let .exactIdentifier(id): l("evidence.exact", "此位置名称与应用标识符完全一致：") + id
        case let .preferenceDomain(id): l("evidence.preference", "偏好设置域与应用标识符一致：") + id
        case let .savedState(id): l("evidence.state", "保存状态目录使用应用标识符：") + id
        case let .containerMetadata(id): l("evidence.container", "容器元数据标识符一致：") + id
        case let .groupEntitlement(id): l("evidence.group", "应用签名声明共享组：") + id
        case let .competingApplication(path): l("evidence.competing", "其他应用使用同一标识符：") + path
        case let .executableInBundle(path): l("evidence.executable", "服务程序位于应用包内：") + path
        case .conflictingMetadata: l("evidence.conflict", "容器元数据与目录名称不一致。")
        }
    }
}

private struct UninstallQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
