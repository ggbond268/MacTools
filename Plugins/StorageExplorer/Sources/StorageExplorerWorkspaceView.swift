import AppKit
import MacToolsPluginKit
import SwiftUI

public struct StorageExplorerWorkspaceView: View {
    @ObservedObject public var controller: StorageExplorerController
    public let localization: PluginLocalization
    @State private var showsInspector = false
    @State private var sortOrder = [KeyPathComparator(\StorageExplorerRow.bytes, order: .reverse)]

    public init(controller: StorageExplorerController,
                localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.controller = controller
        self.localization = localization
    }

    private func text(_ key: String, _ fallback: String) -> String {
        localization.string("storageExplorer." + key, defaultValue: fallback)
    }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.height < 520 {
                ScrollView { workspace(width: geometry.size.width, height: 520).frame(height: 520) }
            } else {
                workspace(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func workspace(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            controls
            if controller.rootItem != nil || controller.isScanning {
                StorageExplorerProgressView(
                    status: controller.status,
                    scanning: controller.isScanning,
                    metric: controller.metric,
                    localization: localization
                )
                navigation(compact: width < 780)
                if width >= 780 {
                    HSplitView {
                        explorer(height: height).frame(minWidth: 400)
                        inspector.frame(minWidth: 190, idealWidth: 220, maxWidth: 280,
                                        maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    explorer(height: height)
                }
                reviewBar
            } else {
                ContentUnavailableView(text("emptyStateTitle", "选择要分析的文件夹"), systemImage: "internaldrive",
                    description: Text(text("exploreDescription", "查看空间分布、查找大文件，审阅后移至废纸篓。")))
            }
            if controller.isStale {
                Label(text("changedOnDisk", "文件已更改。刷新可更新大小；仍可浏览，移至废纸篓前会重新验证所选项目。"), systemImage: "arrow.triangle.2.circlepath")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
            }
            if let error = controller.lastErrorMessage {
                Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red).textSelection(.enabled)
            }
            if let success = controller.lastSuccessMessage {
                Text(success).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
        .padding(PluginSettingsTheme.Spacing.section)
        .sheet(isPresented: $controller.isConfirmingTrash) { confirmation }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            let key: StorageExplorerSort = first.keyPath == \StorageExplorerRow.name ? .name
                : first.keyPath == \StorageExplorerRow.kind ? .kind
                : first.keyPath == \StorageExplorerRow.modified ? .modified : .size
            controller.setSort(key, ascending: first.order == .forward)
        }
    }

    private func explorer(height: CGFloat) -> some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            StorageExplorerTreemapView(
                rows: controller.chartRows,
                selection: $controller.selectedPath,
                basket: controller.basket,
                otherLabel: text("other", "其他"),
                emptyLabel: text("noSizedItems", "尚无可显示的大小"),
                addReviewLabel: text("addToReview", "加入审阅"),
                removeReviewLabel: text("removeFromReview", "移出审阅"),
                open: { controller.drillDown(to: $0.item) },
                navigateUp: controller.navigateUp,
                toggleReview: { controller.toggleSelection(path: $0.item.path) }
            )
            .frame(minHeight: 180, idealHeight: min(height * 0.38, 340), maxHeight: min(height * 0.5, 440))
            fileTable.frame(minHeight: 110, maxHeight: .infinity)
            if controller.matchingCount > controller.rows.count {
                Text(String(format: text("limitedRows", "显示前 %d 项，共 %d 项；搜索可缩小范围。"),
                            controller.rows.count, controller.matchingCount))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button { controller.scanHomeFolder() } label: { Label(text("homeFolder", "个人目录"), systemImage: "house") }
            Button { controller.selectFolderAndScan() } label: { Label(text("selectFolder", "选择文件夹…"), systemImage: "folder.badge.plus") }
            Spacer()
            if controller.isScanning {
                Button(text("cancel", "取消"), role: .cancel) { controller.cancelScan() }
            } else if let root = controller.scanRootURL {
                Button { controller.startScan(at: root) } label: { Label(text("refresh", "刷新"), systemImage: "arrow.clockwise") }
                    .contextMenu {
                        Button(text("rescan", "重新扫描")) { controller.startScan(at: root, force: true) }
                    }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(controller.isExecutingTrash)
    }

    private func navigation(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(controller.navigationStack.enumerated()), id: \.element.path) { index, item in
                        if index > 0 { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        Button(item.name.isEmpty ? "/" : item.name) { controller.navigateToBreadcrumb(at: index) }
                            .buttonStyle(.plain)
                    }
                }
                .font(PluginSettingsTheme.Typography.rowTitle)
            }
            HStack {
                Picker(text("viewMode", "视图"), selection: $controller.mode) {
                    Text(text("folders", "文件夹")).tag(StorageExplorerMode.folders)
                    Text(text("largestFiles", "大文件")).tag(StorageExplorerMode.largestFiles)
                    Text(text("fileTypes", "文件类型")).tag(StorageExplorerMode.fileTypes)
                }.pickerStyle(.segmented).frame(minWidth: 200, idealWidth: 260, maxWidth: 300)
                Picker(text("sizeMetric", "大小"), selection: $controller.metric) {
                    Text(text("logicalSize", "文件大小")).tag(StorageExplorerMetric.logical)
                    Text(text("allocatedSize", "占用空间")).tag(StorageExplorerMetric.allocated)
                }.labelsHidden().frame(width: 120)
                Spacer(minLength: 8)
                if compact {
                    Button { showsInspector.toggle() } label: { Image(systemName: "info.circle") }
                        .help(text("details", "详细信息"))
                        .popover(isPresented: $showsInspector) { inspector.frame(width: 280, height: 420).padding(12) }
                } else {
                    TextField(text("search", "搜索…"), text: $controller.searchQuery)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 100, idealWidth: 150, maxWidth: 200)
                }
            }.controlSize(.small)
            if compact {
                TextField(text("search", "搜索…"), text: $controller.searchQuery).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var fileTable: some View {
        Table(controller.rows, selection: $controller.selectedPath, sortOrder: $sortOrder) {
            TableColumn("") { row in
                Button {
                    controller.toggleSelection(path: row.item.path)
                } label: {
                    Image(systemName: controller.basket.contains(row.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(controller.basket.contains(row.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!controller.canStage(row.item))
                .help(controller.basket.contains(row.id) ? text("removeFromReview", "移出审阅") : text("addToReview", "加入审阅"))
            }
            .width(24)
            TableColumn(text("nameColumn", "名称"), value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.item.iconSystemName).foregroundStyle(.secondary)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.item.isIncomplete { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    if controller.basket.contains(row.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                .help(row.item.path)
            }.width(min: 140, ideal: 220)
            TableColumn(text("sizeColumn", "大小"), value: \.bytes) { row in
                Text(row.sizeLabel).monospacedDigit()
            }.width(min: 70, ideal: 90)
            TableColumn(text("proportionColumn", "占比")) { row in Text(row.percentage).monospacedDigit() }
                .width(min: 45, ideal: 55)
            TableColumn(text("kind", "类型"), value: \.kind) { row in
                Text(row.item.isDirectory && !row.item.isPackage ? text("folders", "文件夹") : row.kind)
            }.width(min: 60, ideal: 80)
            TableColumn(text("modified", "修改日期"), value: \.modified) { row in Text(row.dateLabel) }
                .width(min: 80, ideal: 95)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first, let item = controller.rows.first(where: { $0.id == path })?.item {
                Button(text("openFolder", "打开文件夹")) { controller.drillDown(to: item) }
                    .disabled(!item.isDirectory || item.isPackage)
                Button(text("revealInFinder", "在访达中显示")) { controller.revealInFinder(path: path) }
                    .disabled(path.hasPrefix("type:"))
                Button(text("addToReview", "加入审阅")) { controller.toggleSelection(path: path) }
                    .disabled(!controller.canStage(item))
            }
        } primaryAction: { paths in
            if let path = paths.first, let item = controller.rows.first(where: { $0.id == path })?.item {
                controller.drillDown(to: item)
            }
        }
        .accessibilityLabel(text("results", "扫描结果"))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                Label(text("details", "详细信息"), systemImage: "info.circle")
                    .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                if let item = controller.inspectedItem {
                    Text(item.name).font(PluginSettingsTheme.Typography.emphasizedRowTitle).textSelection(.enabled)
                    if !item.path.hasPrefix("type:") {
                        Text(item.path).font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    detail(text("logicalSize", "文件大小"), ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    detail(text("allocatedSize", "占用空间"), ByteCountFormatter.string(fromByteCount: item.allocatedSize, countStyle: .file))
                    if item.isAccessDenied { Label(text("accessDenied", "无访问权限"), systemImage: "lock.fill").foregroundStyle(.orange) }
                    if item.isCloudPlaceholder { Label(text("cloudPlaceholder", "仅在云端"), systemImage: "icloud").foregroundStyle(.secondary) }
                    if item.isIncomplete { Text(text("incomplete", "大小尚不完整" )).foregroundStyle(.orange) }
                    Text(text("spaceNote", "占用空间不等于可释放空间；共享数据和废纸篓会影响实际可用容量。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    if !item.path.hasPrefix("type:") {
                        Button(text("revealInFinder", "在访达中显示")) { controller.revealInFinder(path: item.path) }
                        Button(controller.basket.contains(item.path) ? text("removeFromReview", "移出审阅") : text("addToReview", "加入审阅")) {
                            controller.toggleSelection(path: item.path)
                        }.disabled(!controller.canStage(item))
                        if !item.isDirectory && !item.isSymlink && !item.isCloudPlaceholder {
                            StorageExplorerQuickLookView(url: item.url).frame(height: 170)
                        }
                    }
                } else {
                    Text(text("selectToInspect", "选择图块或列表项目以查看详情。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
            }.padding(.leading, 12).padding(.trailing, 4)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            Text(value).font(PluginSettingsTheme.Typography.monospacedValue)
        }
    }

    private var reviewBar: some View {
        HStack {
            Button(text("selectVisible", "选择列表项目")) { controller.selectAllVisible(items: controller.rows.map(\.item)) }
                .disabled(controller.isScanning || controller.mode == .fileTypes)
            Spacer()
            Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), controller.basket.count,
                ByteCountFormatter.string(fromByteCount: controller.totalSelectedBytes, countStyle: .file)))
                .font(PluginSettingsTheme.Typography.rowDescription).monospacedDigit()
            Button(text("clearSelection", "取消选择")) { controller.clearSelection() }.disabled(controller.basket.isEmpty)
            Button(text("review", "审阅…")) { controller.confirmTrash() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.basket.isEmpty || controller.isScanning)
        }.buttonStyle(.bordered).controlSize(.small)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Label(text("confirmTrashTitle", "移至废纸篓确认"), systemImage: "trash")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            Text(text("confirmTrashMessage", "所选项目将移至 macOS 废纸篓，可从废纸篓恢复。"))
            List(controller.reviewItems) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(height: 220)
            Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), controller.reviewItems.count,
                ByteCountFormatter.string(fromByteCount: controller.reviewItems.reduce(0) { $0 + controller.metric.bytes($1) }, countStyle: .file)))
            HStack {
                Spacer()
                Button(text("cancel", "取消"), role: .cancel) { controller.isConfirmingTrash = false }
                Button(text("moveToTrash", "移至废纸篓…"), role: .destructive) { Task { await controller.executeTrash() } }
                    .disabled(controller.isExecutingTrash)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(controller.isExecutingTrash)
    }
}

private struct StorageExplorerProgressView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let scanning: Bool
    let metric: StorageExplorerMetric
    let localization: PluginLocalization
    var body: some View {
        HStack(spacing: 16) {
            if scanning { ProgressView().controlSize(.small) }
            Text(ByteCountFormatter.string(
                fromByteCount: metric == .logical
                    ? status.progress.bytesScanned
                    : status.progress.allocatedBytesScanned,
                countStyle: .file
            ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle).monospacedDigit()
            Text(String(format: localization.string("storageExplorer.filesScannedFormat", defaultValue: "已扫描 %d 个项目"), status.progress.filesScanned))
            Text(String(format: "%.1f s", status.progress.elapsed)).monospacedDigit()
            if status.progress.skippedCount > 0 {
                Label(String(format: localization.string("storageExplorer.skippedCount", defaultValue: "跳过 %d 项"), status.progress.skippedCount),
                      systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            Spacer()
            if scanning { Text(status.progress.currentPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .padding(12).pluginSettingsCardBackground(.standard)
    }
}
