import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

public struct StorageExplorerWorkspaceView: View {
    @ObservedObject public var controller: StorageExplorerController
    public let localization: PluginLocalization

    public init(
        controller: StorageExplorerController,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.controller = controller
        self.localization = localization
    }

    public var body: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.section) {
            topControlBar

            if case let .scanning(progress) = controller.scanState {
                scanningBanner(progress: progress)
            }

            if let current = controller.currentDirectory {
                navigationAndFilterBar
                selectionBanner
                fileListView(current: current)
            } else if case .scanning = controller.scanState {
                scanningPlaceholderView
            } else {
                emptyStateView
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.pagePadding)
        .padding(.vertical, PluginSettingsTheme.Spacing.section)
        .sheet(isPresented: $controller.isConfirmingTrash) {
            trashConfirmationSheet
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button {
                controller.scanHomeFolder()
            } label: {
                Label(
                    localization.string("storageExplorer.homeFolder", defaultValue: "个人目录"),
                    systemImage: "house"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                controller.selectFolderAndScan()
            } label: {
                Label(
                    localization.string("storageExplorer.selectFolder", defaultValue: "选择文件夹..."),
                    systemImage: "folder.badge.plus"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if case .scanning = controller.scanState {
                Button(role: .cancel) {
                    controller.cancelScan()
                } label: {
                    Label(
                        localization.string("storageExplorer.cancel", defaultValue: "取消"),
                        systemImage: "xmark"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let rootURL = controller.scanRootURL {
                Button {
                    controller.startScan(at: rootURL)
                } label: {
                    Label(
                        localization.string("storageExplorer.rescan", defaultValue: "重新扫描"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Scanning Banner

    private func scanningBanner(progress: StorageExplorerScanProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string("storageExplorer.scanning", defaultValue: "正在扫描..."))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(progress.currentPath)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(String(format: localization.string("storageExplorer.filesScannedFormat", defaultValue: "已扫描 %d 个项目"), progress.filesScanned))
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.secondary)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.standard)
    }

    // MARK: - Navigation & Filter Bar

    private var navigationAndFilterBar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button {
                controller.navigateUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.navigationStack.count <= 1)

            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(controller.navigationStack.enumerated()), id: \.offset) { index, item in
                        Button {
                            controller.navigateToBreadcrumb(at: index)
                        } label: {
                            Text(index == 0 ? (item.name.isEmpty ? "/" : item.name) : item.name)
                                .font(index == controller.navigationStack.count - 1
                                    ? PluginSettingsTheme.Typography.emphasizedRowTitle
                                    : PluginSettingsTheme.Typography.rowTitle)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == controller.navigationStack.count - 1 ? .primary : .secondary)

                        if index < controller.navigationStack.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            // Search filter field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    localization.string("storageExplorer.searchPlaceholder", defaultValue: "过滤当前目录..."),
                    text: $controller.searchQuery
                )
                .textFieldStyle(.plain)
                .frame(width: 140)

                if !controller.searchQuery.isEmpty {
                    Button {
                        controller.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PluginSettingsTheme.Palette.recessedControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous))
        }
    }

    // MARK: - Selection Review Banner

    @ViewBuilder
    private var selectionBanner: some View {
        if !controller.basket.isEmpty {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)

                Text(String(
                    format: localization.string("storageExplorer.selectedItemsFormat", defaultValue: "已选 %d 个项目（共 %@）"),
                    controller.basket.count,
                    ByteCountFormatter.string(fromByteCount: controller.totalSelectedBytes, countStyle: .file)
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)

                Spacer()

                Button {
                    controller.clearSelection()
                } label: {
                    Text(localization.string("storageExplorer.clearSelection", defaultValue: "取消选择"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    controller.confirmTrash()
                } label: {
                    Label(
                        localization.string("storageExplorer.moveToTrash", defaultValue: "移至废纸篓..."),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .pluginSettingsCardBackground(.standard)
        }
    }

    // MARK: - File List View

    private func fileListView(current: StorageItem) -> some View {
        let items = filteredItems(in: current)
        let totalSize = max(current.size, 1)

        return VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Button {
                    if controller.basket.count == items.count {
                        controller.clearSelection()
                    } else {
                        controller.selectAllVisible(items: items)
                    }
                } label: {
                    Image(systemName: controller.basket.count == items.count && !items.isEmpty
                        ? "checkmark.square.fill"
                        : (controller.basket.isEmpty ? "square" : "minus.square.fill"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(localization.string("storageExplorer.nameColumn", defaultValue: "名称"))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(localization.string("storageExplorer.proportionColumn", defaultValue: "占比"))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)

                Text(localization.string("storageExplorer.sizeColumn", defaultValue: "大小"))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)

                Text(localization.string("storageExplorer.actionsColumn", defaultValue: "操作"))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, 8)

            PluginSettingsListDivider()

            if items.isEmpty {
                HStack {
                    Spacer()
                    Text(localization.string("storageExplorer.noMatchingItems", defaultValue: "没有匹配的项目"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 32)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            fileRow(item: item, totalDirectorySize: totalSize)
                            if item.id != items.last?.id {
                                PluginSettingsListDivider()
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .pluginSettingsCardBackground(.standard)
    }

    private func fileRow(item: StorageItem, totalDirectorySize: Int64) -> some View {
        let isSelected = controller.basket.contains(item.path)
        let proportion = totalDirectorySize > 0 ? Double(item.size) / Double(totalDirectorySize) : 0.0

        return HStack(spacing: 12) {
            // Checkbox
            Button {
                controller.toggleSelection(path: item.path)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            // Icon
            Image(systemName: item.iconSystemName)
                .pluginSettingsRowIconStyle(item.isDirectory ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))

            // Name and detail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.isDirectory && !item.isPackage {
                    Text(String(format: localization.string("storageExplorer.itemsCountFormat", defaultValue: "%d 个项目"), item.childCount))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                } else if let modDate = item.modificationDate {
                    Text(modDate.formatted(date: .abbreviated, time: .shortened))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Proportional Size Bar
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PluginSettingsTheme.Palette.recessedControlBackground)
                        Capsule()
                            .fill(item.isDirectory ? Color.accentColor : Color.orange)
                            .frame(width: max(geo.size.width * CGFloat(proportion), 3))
                    }
                }
                .frame(width: 80, height: 8)

                Text(String(format: "%.1f%%", proportion * 100))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .frame(width: 140, alignment: .leading)

            // Formatted Size
            Text(item.formattedSize)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .frame(width: 80, alignment: .trailing)

            // Actions
            HStack(spacing: 6) {
                Button {
                    controller.revealInFinder(path: item.path)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localization.string("storageExplorer.revealInFinder", defaultValue: "在访达中显示"))

                if item.isDirectory && !item.isPackage {
                    Button {
                        controller.drillDown(to: item)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 14)
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .pluginSettingsListRowPadding()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory && !item.isPackage {
                controller.drillDown(to: item)
            }
        }
    }

    private func filteredItems(in directory: StorageItem) -> [StorageItem] {
        let query = controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return directory.children
        }
        return directory.children.filter { $0.name.lowercased().contains(query) }
    }

    // MARK: - Empty State & Placeholders

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(localization.string("storageExplorer.emptyStateTitle", defaultValue: "选择要分析的文件夹"))
                .font(PluginSettingsTheme.Typography.pageTitle)

            Text(localization.string("storageExplorer.emptyStateDescription", defaultValue: "快速扫描任意文件夹或个人目录，直观了解磁盘占用分布。"))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button {
                    controller.scanHomeFolder()
                } label: {
                    Label(
                        localization.string("storageExplorer.homeFolder", defaultValue: "扫描个人目录"),
                        systemImage: "house.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    controller.selectFolderAndScan()
                } label: {
                    Label(
                        localization.string("storageExplorer.selectFolder", defaultValue: "选择文件夹..."),
                        systemImage: "folder.badge.plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
        .pluginSettingsCardBackground(.standard)
    }

    private var scanningPlaceholderView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(localization.string("storageExplorer.scanning", defaultValue: "正在扫描目录结构..."))
                .font(PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
        .pluginSettingsCardBackground(.standard)
    }

    // MARK: - Trash Confirmation Sheet

    private var trashConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(Color.red)
                    .font(.title2)
                Text(localization.string("storageExplorer.confirmTrashTitle", defaultValue: "移至废纸篓确认"))
                    .font(PluginSettingsTheme.Typography.sectionTitle)
            }

            Text(localization.string("storageExplorer.confirmTrashMessage", defaultValue: "所选项目将被移动至 macOS 废纸篓。如有需要，您可以从废纸篓恢复它们。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            // Items list with safety validation
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(controller.basket), id: \.self) { path in
                        let validation = controller.safetyPolicy.validatePathForRemoval(
                            path,
                            withinRoot: controller.scanRootURL?.path ?? ""
                        )

                        HStack {
                            Image(systemName: validation.isAllowed ? "doc.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(validation.isAllowed ? Color.secondary : Color.orange)

                            Text(path)
                                .font(PluginSettingsTheme.Typography.monospacedValue)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            if !validation.isAllowed {
                                Text(validation.reason ?? "受保护")
                                    .font(PluginSettingsTheme.Typography.statusBadge)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(PluginSettingsTheme.Palette.recessedControlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Text(String(
                    format: localization.string("storageExplorer.selectedItemsFormat", defaultValue: "共 %d 个项目（%@）"),
                    controller.basket.count,
                    ByteCountFormatter.string(fromByteCount: controller.totalSelectedBytes, countStyle: .file)
                ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Spacer()

                Button(localization.string("storageExplorer.cancel", defaultValue: "取消")) {
                    controller.isConfirmingTrash = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(role: .destructive) {
                    Task {
                        await controller.executeTrash()
                    }
                } label: {
                    if controller.isExecutingTrash {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(localization.string("storageExplorer.confirmTrashButton", defaultValue: "确认移至废纸篓"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(controller.isExecutingTrash)
            }
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(minWidth: 480, minHeight: 340)
    }
}
