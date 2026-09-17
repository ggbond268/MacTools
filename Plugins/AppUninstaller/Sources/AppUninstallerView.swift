import AppKit
import QuickLookUI
import SwiftUI
import MacToolsPluginKit

struct AppUninstallerView: View {
    @ObservedObject var controller: AppUninstallerController
    let localization: PluginLocalization
    @State private var showsHistory = false
    @State private var search = ""
    @State private var previewURL: URL?
    @State private var confirmsSource = false
    @State private var showsForceQuit = false
    @State private var showsXcodeStorageHandoff = false

    private enum InventoryFilter: Hashable { case all, reviewable, otherTool }
    @State private var inventoryFilter: InventoryFilter = .all

    private func l(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                header
                HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    inventoryPane.frame(width: min(340, max(240, geometry.size.width * 0.36)))
                    detailPane.frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                batchFooter
            }
            .padding(PluginSettingsTheme.Spacing.section)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "app" }) else { return false }
            controller.addApplications(urls); return true
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL {
                VStack {
                    UninstallQuickLookView(url: previewURL).frame(width: 520, height: 360)
                    Button(l("browser.done", "完成")) { self.previewURL = nil }.keyboardShortcut(.cancelAction)
                }.padding(16)
            }
        }
        .sheet(isPresented: $showsHistory) {
            ScrollView { history.padding(20) }
                .frame(minWidth: 620, idealWidth: 760, minHeight: 400, idealHeight: 600)
        }
        .sheet(item: $controller.pendingPlan) { plan in confirmation(plan) }
        .sheet(item: $controller.pendingBatchPlan) { plan in batchConfirmation(plan) }
        .confirmationDialog(l("xcode.storageWarningTitle", "共享 Xcode 数据"), isPresented: $showsXcodeStorageHandoff,
                            titleVisibility: .visible) {
            Button(l("xcode.openStorage", "查看 Xcode 存储")) { controller.openXcodeStorage?() }
            Button(l("plan.cancel", "取消"), role: .cancel) {}
        } message: {
            Text(l("xcode.storageWarning", "Xcode 清理是独立操作；选中的文件会被永久删除，也可能被正式版 Xcode 使用。"))
        }
        .onAppear { controller.browseIfNeeded() }
        .onDisappear { controller.cancelScans() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(l("inventory.title", "已安装应用"), systemImage: "square.stack.3d.up")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer(minLength: 8)
                Button(l("review.choose", "选择应用…"), action: controller.choose)
                Button { controller.browse() } label: { Image(systemName: "arrow.clockwise") }
                    .help(l("inventory.refresh", "刷新应用列表"))
                Button { showsHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help(l("history.title", "移除记录"))
            }.buttonStyle(.bordered).controlSize(.small)
            Text(l("inventory.intro", "选择一个或多个应用。关联数据只在审阅所选应用时检查；确认之前不会移动任何内容。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        }
    }

    private var inventoryPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(l("browser.search", "搜索应用名称或标识符"), text: $search)
                .textFieldStyle(.roundedBorder)
            Picker(l("inventory.filter", "显示"), selection: $inventoryFilter) {
                Text(l("inventory.all", "全部")).tag(InventoryFilter.all)
                Text(l("inventory.reviewable", "可审阅")).tag(InventoryFilter.reviewable)
                Text(l("inventory.otherTool", "需其他工具")).tag(InventoryFilter.otherTool)
            }.pickerStyle(.segmented).labelsHidden()
            if controller.isBrowsing {
                HStack { ProgressView().controlSize(.small); Text(l("inventory.scanning", "正在查找应用…")) }
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
            if let inventory = controller.inventory, !inventory.complete {
                let issues = inventory.coverage.filter { $0.issue != nil }
                DisclosureGroup(l("inventory.partial", "应用列表未检查完整") + " (\(issues.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l("inventory.partialHelp", "部分应用仍可浏览；所选应用的检查不完整时不会允许移除。"))
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(issues.enumerated()), id: \.offset) { _, entry in
                                    Text(localizedNote(entry.path) + " · " + localizedNote(entry.issue ?? ""))
                                        .lineLimit(2).help(entry.path)
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 6)
                }.foregroundStyle(.orange)
            }
            if let inventoryError = controller.inventoryError {
                Label(inventoryError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
            List {
                if !addedApplicationPaths.isEmpty {
                    Section(l("inventory.added", "手动添加")) {
                        ForEach(addedApplicationPaths, id: \.self) { path in
                            HStack {
                                Button { controller.review(URL(fileURLWithPath: path), includeInBatch: false) } label: {
                                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "app")
                                        .lineLimit(1)
                                }.buttonStyle(.plain)
                                Spacer()
                                Button { controller.setApplicationSelected(path, selected: false) } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.plain).help(l("inventory.removeAdded", "从清单中移除"))
                            }.help(path)
                        }
                    }
                }
                Section(l("inventory.apps", "应用")) {
                    ForEach(filteredApps) { app in inventoryRow(app) }
                }
                if let inventory = controller.inventory, !inventory.unattachedComponents.isEmpty {
                    Section(l("inventory.components", "独立列出的组件")) {
                        ForEach(inventory.unattachedComponents) { app in inventoryRow(app) }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if !controller.isBrowsing && filteredApps.isEmpty && addedApplicationPaths.isEmpty {
                    ContentUnavailableView(l("inventory.empty", "没有匹配的应用"), systemImage: "app.dashed")
                }
            }
        }
        .padding(12).pluginSettingsCardBackground(.standard)
    }

    private var filteredApps: [UninstallApplication] {
        (controller.inventory?.topLevelApps ?? []).filter { app in
            let matches = search.isEmpty || app.name.localizedStandardContains(search)
                || app.bundleID.localizedStandardContains(search) || app.path.localizedStandardContains(search)
            guard matches else { return false }
            switch inventoryFilter {
            case .all: return true
            case .reviewable: return controller.canIncludeInBatch(app)
            case .otherTool: return !controller.canIncludeInBatch(app)
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var addedApplicationPaths: [String] {
        let discovered = Set(controller.inventory?.apps.map(\.path) ?? [])
        return controller.selectedApplicationPaths.subtracting(discovered).sorted()
    }

    private func reviewedComponents(of app: UninstallApplication) -> [UninstallApplication] {
        guard let scan = controller.scan, scan.application.path == app.path else { return [] }
        return scan.inventory.filter { $0.path != app.path && UninstallPaths.contains($0.path, in: app.path) }
            .sorted { $0.path < $1.path }
    }

    private func inventoryRow(_ app: UninstallApplication) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { controller.selectedApplicationPaths.contains(app.path) },
                                 set: { controller.setApplicationSelected(app.path, selected: $0) })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(!controller.canIncludeInBatch(app) || controller.isRemoving)
                .accessibilityLabel(l("inventory.select", "选择应用：") + app.name)
            Button { controller.review(URL(fileURLWithPath: app.path), includeInBatch: false) } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(PluginSettingsTheme.Typography.rowTitle).lineLimit(1)
                        Text(controller.canIncludeInBatch(app) ? app.version : sourceTitle(app.source))
                            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if !reviewedComponents(of: app).isEmpty {
                        let count = reviewedComponents(of: app).count
                        Image(systemName: "puzzlepiece.extension").help(String(format: l("inventory.componentCount", "%d 个组件"), count))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .listRowBackground(controller.selectedPath == app.path ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                if let result = controller.batchResult {
                    Label(String(format: l("batch.result", "已完成 %d/%d 个应用。请查看逐项结果。"), result.completed, result.total),
                          systemImage: result.completed == result.total ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Button(l("batch.viewResults", "查看结果与恢复位置")) { showsHistory = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if controller.isRemoving {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(String(format: l("batch.removing", "正在处理应用 %d/%d…"), controller.batchProgress + 1,
                                    max(controller.selectedApplicationPaths.count, 1)))
                        Button(l("review.stop", "停止"), action: controller.cancel)
                    }
                }
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
                if controller.isPreparingBatch {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(String(format: l("batch.scanning", "正在检查 %d/%d 个应用…"), controller.batchProgress,
                                    controller.selectedApplicationPaths.count))
                    }
                }
                if !controller.batchScans.isEmpty && !controller.isPreparingBatch {
                    batchReview
                } else if let scan = controller.scan {
                    application(scan.application)
                    scanSummary(scan)
                    candidateGroups(scan)
                    coverage(scan)
                } else if controller.isScanning {
                    HStack { ProgressView().controlSize(.small); Text(l("review.scanning", "正在检查应用身份与关联位置…")) }
                } else {
                    ContentUnavailableView(l("inventory.selectPrompt", "选择应用以查看详情"), systemImage: "app.badge.checkmark",
                        description: Text(l("inventory.selectDescription", "左侧可搜索应用，也可拖入应用或从访达选择。")))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).pluginSettingsCardBackground(.standard)
    }

    private var batchFooter: some View {
        HStack(spacing: 12) {
            Text(String(format: l("batch.selectedApps", "已选择 %d 个应用"), controller.selectedApplicationPaths.count))
                .font(PluginSettingsTheme.Typography.rowTitle)
            if !controller.selectedApplicationPaths.isEmpty {
                Button(l("batch.clearApps", "清除选择"), action: controller.clearSelectedApplications)
            }
            Spacer(minLength: 8)
            if controller.isPreparingBatch {
                Button(l("review.cancel", "取消扫描"), action: controller.cancelScans)
            } else if controller.selectedApplicationPaths.isEmpty {
                Text(l("batch.selectFirst", "先从列表中选择应用"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            } else if Set(controller.batchScans.map(\.application.path)) == controller.selectedApplicationPaths {
                Button(l("batch.reviewRemoval", "检查移除清单…")) { confirmsSource = false; controller.prepareBatchPlan() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(l("batch.scanSelected", "检查所选应用…"), action: controller.reviewSelectedApplications)
                    .buttonStyle(.borderedProminent)
            }
        }.buttonStyle(.bordered).controlSize(.small).disabled(controller.isRemoving)
    }

    private func scanSummary(_ scan: UninstallScan) -> some View {
        let selected = controller.batchSelections[scan.application.path] ?? controller.selectedIDs
        let kept = scan.candidates.filter { !selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(format: l("review.selectionSummary", "%d 项拟移入 · %d 项保留"), selected.count, kept.count))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Text(l("review.scopeShort", "只检查列出的关联位置；文稿、项目和其他位置未搜索。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            if !controller.selectedApplicationPaths.contains(scan.application.path) {
                Button(l("inventory.includeApp", "将此应用加入移除清单")) {
                    controller.setApplicationSelected(scan.application.path, selected: true)
                }.buttonStyle(.bordered).controlSize(.small)
            }
            if !scan.canPlan {
                Label(l("review.incomplete", "检查或安装来源尚未确认；移除不可用。"), systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            } else if !scan.inventoryComplete {
                Label(l("review.appOnly", "应用本体可审阅；应用列表未查全，关联数据将保留。"), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if scan.coverage.contains(where: { $0.issue != nil }) {
                Label(l("review.partialItems", "部分关联位置未查全；只能移除已验证的项目。"), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).pluginSettingsCardBackground(.recessed)
    }

    private func candidateGroups(_ scan: UninstallScan) -> some View {
        Group {
            if scan.application.bundleID.lowercased() == "com.apple.dt.xcode" {
                xcodeDataReview(scan)
            } else {
                standardCandidateGroups(scan)
            }
        }
    }

    private func standardCandidateGroups(_ scan: UninstallScan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(UninstallDataClass.allCases.filter { $0 != .application }, id: \.self) { kind in
                let items = scan.candidates.filter { $0.dataClass == kind }
                if !items.isEmpty {
                    DisclosureGroup(kindTitle(kind) + " · " + String(items.count)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items) { item in candidate(item, appPath: scan.application.path) }
                        }.padding(.top, 8)
                    }.font(PluginSettingsTheme.Typography.rowTitle)
                }
            }
        }
    }

    private func xcodeDataReview(_ scan: UninstallScan) -> some View {
        let app = scan.application
        let appSnapshot = scan.candidates.first { $0.dataClass == .application }?.snapshot
        let exclusive = scan.candidates.filter { $0.dataClass != .application && $0.eligible }
        let retained = scan.candidates.filter { $0.dataClass != .application && !$0.eligible }
        return VStack(alignment: .leading, spacing: 10) {
            Label(l("xcode.scopeTitle", "区分此版本与共享数据"), systemImage: "square.on.square")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l("xcode.thisCopy", "此 Xcode 应用本体"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(app.path).font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let appSnapshot {
                    Text(ByteCountFormatter.string(fromByteCount: appSnapshot.allocatedBytes, countStyle: .file))
                        .font(PluginSettingsTheme.Typography.monospacedValue).fixedSize()
                }
            }
            if exclusive.isEmpty {
                Text(l("xcode.noExclusiveData", "尚未确认任何独属于此副本的外部数据；应用本体通过检查后才可移除。"))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(String(format: l("xcode.exclusiveTitle", "已验证为此副本独有的数据（%d）"), exclusive.count)) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(exclusive) { item in candidate(item, appPath: app.path) }
                    }.padding(.top, 8)
                }.font(PluginSettingsTheme.Typography.rowTitle)
            }
            DisclosureGroup(String(format: l("xcode.sharedTitle", "共享或归属不明的匹配项（%d）"), retained.count)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(l("xcode.sharedExplanation", "下列同标识符数据不会随此副本移除；现有构建数据、归档和模拟器也未被认定为此副本独有。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    ForEach(retained) { item in candidate(item, appPath: app.path) }
                    Button(l("xcode.openStorage", "查看 Xcode 存储")) { showsXcodeStorageHandoff = true }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text(l("xcode.storageWarning", "Xcode 清理是独立操作；选中的文件会被永久删除，也可能被正式版 Xcode 使用。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(PluginSettingsTheme.Typography.rowTitle)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).pluginSettingsCardBackground(.standard)
    }

    private var batchReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(l("batch.reviewTitle", "所选应用的审阅结果"), systemImage: "checklist")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            Text(l("batch.reviewHelp", "每个应用独立检查与记录。展开任一应用以选择要保留的关联数据。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            ForEach(controller.batchScans) { scan in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        scanSummary(scan)
                        candidateGroups(scan)
                        coverage(scan)
                    }.padding(.top, 8)
                } label: {
                    HStack {
                        Text(scan.application.name)
                        Spacer()
                        Text(String(format: l("batch.itemCount", "%d 项拟移入"),
                                    controller.batchSelections[scan.application.path]?.count ?? 0))
                            .foregroundStyle(.secondary)
                        if !scan.canPlan { Image(systemName: "exclamationmark.shield").foregroundStyle(.orange) }
                    }
                }.padding(12).pluginSettingsCardBackground(.standard)
            }
        }
    }

    private func application(_ app: UninstallApplication) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(PluginSettingsTheme.Typography.emphasizedRowTitle).lineLimit(2)
                    Text(app.version).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(controller.processCheckIncomplete ? l("app.stateUnknown", "运行状态待确认")
                     : controller.isRunning ? l("app.running", "正在运行") : l("app.notRunning", "未在运行"))
                    .font(PluginSettingsTheme.Typography.statusBadge)
            }
            Text(sourceTitle(app.source)).font(PluginSettingsTheme.Typography.rowDescription)
            if !app.restrictions.isEmpty {
                Label(l("app.needsOtherTool", "此应用需要其他方式处理；查看下方原因。"), systemImage: "exclamationmark.shield")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
            }
            if app.source == .homebrew {
                Button(l("app.homebrew", "在 Homebrew 中管理")) { controller.openHomebrew?() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            ForEach(app.vendorUninstallers, id: \.self) { path in
                Button(l("app.vendorTool", "在访达中查看厂商卸载工具") + " · " + URL(fileURLWithPath: path).lastPathComponent) {
                    controller.reveal(path)
                }.buttonStyle(.bordered).controlSize(.small)
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
            DisclosureGroup(l("app.details", "应用身份与处理限制")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.path).textSelection(.enabled)
                    Text(app.bundleID).textSelection(.enabled)
                    Text("\(app.version) (\(app.build))")
                    Text(l("app.team", "签名团队：") + (app.teamID ?? l("app.signatureUnknown", "未验证或未签名")))
                    ForEach(Array(app.restrictions.enumerated()), id: \.offset) { _, note in
                        Label(localizedNote(note), systemImage: "info.circle")
                    }
                    let components = reviewedComponents(of: app)
                    if !components.isEmpty {
                        Text(String(format: l("inventory.componentCount", "%d 个组件"), components.count))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        ForEach(components) { component in
                            Text(component.name + " · " + component.path).textSelection(.enabled)
                        }
                        Text(l("inventory.componentHelp", "嵌入式组件应由所属应用管理。"))
                    }
                }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 8)
            }
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
                            Text(localizedNote(entry.path)).textSelection(.enabled).lineLimit(3)
                            Text(entry.issue.map(localizedNote) ?? l("coverage.checked", "已检查或位置不存在"))
                                .foregroundStyle(entry.issue == nil ? Color.secondary : .orange)
                        }
                    }
                    Text(l("coverage.installation", "安装来源仅检查 App Store 收据与常用 Homebrew 安装位置。自定义包管理器、全部厂商卸载程序及所有管理方式尚未验证。"))
                }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 8)
            }
        }.padding(16).pluginSettingsCardBackground(.standard)
    }

    private func candidate(_ item: UninstallCandidate, appPath: String) -> some View {
        let inBatch = controller.batchScans.contains { $0.application.path == appPath }
        let selected = inBatch ? controller.batchSelections[appPath]?.contains(item.id) == true
            : controller.selectedIDs.contains(item.id)
        let expectedRetention = item.blockedReason == "Apple 应用的关联数据将保留。"
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(l("candidate.whyFound", "发现依据" )).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in Text(evidenceText(evidence)).textSelection(.enabled) }
                Text(l("candidate.consequence", "数据用途与可能损失")).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(consequence(item.dataClass))
                if let note = item.blockedReason {
                    Label(localizedNote(note), systemImage: expectedRetention ? "lock.shield" : "exclamationmark.shield")
                        .foregroundStyle(expectedRetention ? Color.secondary : .orange)
                }
                HStack {
                    Button(l("review.reveal", "在访达中显示")) { controller.reveal(item.path) }
                    Button(l("review.copyPath", "拷贝路径")) { controller.copyPath(item.path) }
                }.buttonStyle(.bordered).controlSize(.small)
            }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 10)
        } label: {
            HStack(alignment: .top) {
                Toggle(isOn: Binding(get: { inBatch ? controller.batchSelections[appPath]?.contains(item.id) == true
                                            : controller.selectedIDs.contains(item.id) },
                                     set: { value in
                                         if inBatch { controller.setBatchCandidateSelected(appPath: appPath, itemID: item.id, selected: value) }
                                         else { controller.setSelected(item.id, selected: value) }
                                     })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(!item.eligible || (item.dataClass == .application && controller.selectedApplicationPaths.contains(appPath)))
                    .accessibilityLabel(l("candidate.select", "选择项目：") + item.path)
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(PluginSettingsTheme.Typography.rowTitle).lineLimit(2)
                    Text(kindTitle(item.dataClass)).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    if let reason = item.blockedReason {
                        Text(localizedNote(reason)).font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(expectedRetention ? Color.secondary : .orange)
                    } else if !selected {
                        Text(l("candidate.kept", "保留")).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(item.snapshot.map { ByteCountFormatter.string(fromByteCount: $0.allocatedBytes, countStyle: .file) }
                     ?? (expectedRetention ? l("candidate.keptUnmeasured", "保留 · 未统计")
                                           : l("candidate.incompleteSize", "大小未完整统计")))
                    .font(PluginSettingsTheme.Typography.monospacedValue).fixedSize()
            }
        }.padding(12).pluginSettingsCardBackground(.standard)
    }

    private func batchConfirmation(_ batch: UninstallBatchPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: l("batch.confirmTitle", "确认处理 %d 个应用"), batch.applicationCount))
                .font(.title2)
            Text(String(format: l("batch.confirmSummary", "%d 项拟移入 · %d 项保留 · 估计占用 %@"),
                        batch.itemCount, batch.retainedCount,
                        ByteCountFormatter.string(fromByteCount: batch.estimatedBytes, countStyle: .file)))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Text(l("batch.confirmScope", "仅列出的项目会移入废纸篓。文稿、项目和其他未检查位置不在此清单中；移入废纸篓不会立即释放空间。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            if batch.plans.contains(where: { $0.coverage.contains(where: { $0.issue != nil }) }) {
                Label(l("batch.partialCoverage", "一个或多个应用的检查不完整；不能继续移除。"), systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(batch.plans) { plan in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(plan.application.path).textSelection(.enabled)
                                ForEach(plan.items) { item in
                                    Label(URL(fileURLWithPath: item.path).lastPathComponent + " · " + consequence(item.dataClass),
                                          systemImage: "checkmark.circle")
                                    .help(item.path)
                                }
                                Text(String(format: l("batch.keptCount", "%d 项保留"), plan.retained.count))
                                    .foregroundStyle(.secondary)
                                ForEach(plan.retained) { item in
                                    Text(URL(fileURLWithPath: item.path).lastPathComponent + " · " + kindTitle(item.dataClass))
                                        .foregroundStyle(.secondary).help(item.path)
                                }
                            }.font(PluginSettingsTheme.Typography.rowDescription).padding(.top, 8)
                        } label: {
                            HStack {
                                Text(plan.application.name).font(PluginSettingsTheme.Typography.rowTitle)
                                Spacer()
                                Text(String(format: l("batch.itemCount", "%d 项拟移入"), plan.items.count))
                                    .foregroundStyle(.secondary)
                            }
                        }.padding(10).pluginSettingsCardBackground(.standard)
                    }
                }
            }.frame(minHeight: 130, maxHeight: 330)
            if batch.plans.contains(where: { $0.application.source == .unknown }) {
                Toggle(l("batch.source", "我已检查上述安装来源未知的应用，并确认无需使用原安装工具。"), isOn: $confirmsSource)
                    .toggleStyle(.checkbox)
            }
            if controller.batchProcessCheckIncomplete {
                Label(l("batch.processUnknown", "运行进程检查尚未完成，暂不能移除。"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !controller.batchRunningPaths.isEmpty {
                Label(l("batch.running", "所选应用或组件仍在运行。请保存工作并退出后重试。"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                ForEach(batch.plans.filter { controller.batchRunningPaths.contains($0.application.path) }) { plan in
                    HStack {
                        Text(plan.application.name)
                        Button(l("app.quit", "退出应用")) { controller.quit(plan.application) }
                    }
                }
            }
            Button(l("app.recheck", "重新检查运行状态"), action: controller.refreshBatchRunningState)
                .buttonStyle(.bordered).controlSize(.small)
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    let expired = batch.plans.contains { context.date >= $0.expiresAt }
                    if expired {
                        Label(l("coverage.stale", "结果已过期。请重新扫描以查看当前状态。"), systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button(l("plan.cancel", "取消")) { controller.pendingBatchPlan = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(l("batch.rescan", "重新检查所选应用")) {
                            controller.pendingBatchPlan = nil
                            controller.reviewSelectedApplications()
                        }.disabled(controller.isPreparingBatch)
                        Button(l("plan.trash", "移入废纸篓"), role: .destructive) { controller.removeReviewedBatch(batch) }
                            .buttonStyle(.borderedProminent)
                            .disabled(expired || controller.batchProcessCheckIncomplete || !controller.batchRunningPaths.isEmpty
                                      || (batch.plans.contains(where: { $0.application.source == .unknown }) && !confirmsSource))
                    }
                }
            }
        }.padding(20).frame(minWidth: 600, idealWidth: 720)
            .interactiveDismissDisabled(controller.isRemoving)
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
        if controller.runs.isEmpty {
            ContentUnavailableView(l("history.empty", "尚无移除记录"), systemImage: "clock.arrow.circlepath")
        } else {
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
                                    if let message = result.message { Text(localizedNote(message)).foregroundStyle(.secondary) }
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

    private func localizedNote(_ raw: String) -> String {
        let servicePrefix = "存在关联的启动服务："
        let serviceSuffix = "。请使用开发者提供的卸载方式。"
        if raw.hasPrefix(servicePrefix), raw.hasSuffix(serviceSuffix) {
            let name = String(raw.dropFirst(servicePrefix.count).dropLast(serviceSuffix.count))
            return String(format: l("note.relatedService", "发现关联的启动服务：%@。请使用开发者提供的卸载方式。"), name)
        }
        let restorePrefix = "未能恢复原位置："
        if raw.hasPrefix(restorePrefix) {
            return l("note.restoreFailed", "未能恢复原位置：") + localizedNote(String(raw.dropFirst(restorePrefix.count)))
        }
        let ioPrefix = "无法访问项目（"
        if raw.hasPrefix(ioPrefix), raw.hasSuffix("）。"),
           let code = Int32(raw.dropFirst(ioPrefix.count).dropLast(2)) {
            return String(format: l("error.io", "无法访问项目（%d）。"), code)
        }
        switch raw {
        case "无法读取有效的应用身份。": return l("error.invalidApplication", raw)
        case "路径包含链接、受保护位置或不支持的卷。": return l("error.unsafePath", raw)
        case "检查未完成，请查看扫描范围并重新扫描。": return l("error.incomplete", raw)
        case "项目已变化，请重新扫描。": return l("error.changed", raw)
        case "检查结果已过期，请重新扫描。": return l("error.expired", raw)
        case "应用或其组件仍在运行，请退出后重试。": return l("error.running", raw)
        case "此项目需要使用原安装工具或由管理员处理。": return l("error.blocked", raw)
        case "系统应用受保护。": return l("note.systemProtected", raw)
        case "MacTools 及其数据受保护。": return l("note.selfProtected", raw)
        case "嵌入式应用应由所属应用管理。": return l("note.embedded", raw)
        case "此应用位于常用安装目录之外。": return l("note.outsideRoots", raw)
        case "包含特权辅助工具，请使用开发者提供的卸载方式。": return l("note.privilegedHelper", raw)
        case "包含系统组件，请使用开发者提供的卸载方式。": return l("note.systemComponents", raw)
        case "无法检查应用内的系统组件。": return l("note.componentCheck", raw)
        case "无法检查安装收据。": return l("note.receiptCheck", raw)
        case "嵌入式应用检查不完整。": return l("note.embeddedCheck", raw)
        case "此位置未完成应用身份检查。": return l("note.identityCheck", raw)
        case "应用目录无法完整读取。": return l("note.appDirectory", raw)
        case "运行中的应用身份无法读取。": return l("note.runningIdentity", raw)
        case "无法完整检查应用自带的卸载工具。": return l("note.vendorCheck", raw)
        case "发现可能的厂商卸载工具，请先检查其说明。": return l("note.vendorFound", raw)
        case "由 Homebrew 管理，请前往 Homebrew 插件卸载。": return l("note.homebrew", raw)
        case "另一个已安装的应用使用相同标识符。": return l("note.competing", raw)
        case "Apple 应用的关联数据将保留。": return l("note.appleDataRetained", raw)
        case "已安装应用检查不完整，归属仍需核实。": return l("note.inventoryIncomplete", raw)
        case "此位置仅供查看，无法确认独占归属。": return l("note.viewOnly", raw)
        case "大小或路径检查不完整。": return l("note.sizeIncomplete", raw)
        case "项目类型与此关联规则不一致。": return l("note.wrongType", raw)
        case "容器元数据与所选应用不一致。": return l("note.containerMismatch", raw)
        case "无法验证容器的所属应用。": return l("note.containerUnknown", raw)
        case "签名中的共享组信息无法验证，此位置检查不完整。": return l("note.groupUnknown", raw)
        case "关联位置无法读取。": return l("note.associatedUnreadable", raw)
        case "设备已注册管理或管理状态不明确，请联系管理员。": return l("note.managed", raw)
        case "设备管理状态阻止移除。": return l("note.managedCoverage", raw)
        case "无法确认设备管理状态，仅可检查文件。": return l("note.managedUnknown", raw)
        case "管理状态检查未完成。": return l("note.managedCheck", raw)
        case "Homebrew 安装记录检查未完成。": return l("note.homebrewCheck", raw)
        case "后台服务检查未完成。": return l("note.backgroundServiceCheck", raw)
        case "部分运行进程的可执行文件路径不可用，无法确认应用已完全退出。": return l("note.processPathUnknown", raw)
        case "运行进程检查不完整。": return l("note.processCheck", raw)
        case "设备管理": return l("note.deviceManagement", raw)
        case "运行进程": return l("note.runningProcesses", raw)
        case "操作已停止，项目保留原位。": return l("note.itemStopped", raw)
        case "操作中断时，请检查原位置及暂存位置。": return l("note.stagingAttention", raw)
        case "已移入废纸篓；未测量实际回收空间。": return l("note.trashedNoSpace", raw)
        default: return raw
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
