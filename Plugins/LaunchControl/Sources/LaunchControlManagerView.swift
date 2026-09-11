import SwiftUI
import MacToolsPluginKit

@MainActor
final class LaunchControlSettingsSearchFocusController: ObservableObject {
    @Published private(set) var requestID: UInt = 0

    func requestFocus() {
        requestID &+= 1
    }
}

enum LaunchControlManagerLayout {
    static let compactWidthThreshold: CGFloat = 720
    static let compactHeightThreshold: CGFloat = 520
    static let minimumSidebarWidth: CGFloat = 260
    static let maximumSidebarWidth: CGFloat = 340
    static let sidebarWidthRatio: CGFloat = 0.36

    static func usesCompactPresentation(for width: CGFloat) -> Bool {
        width < compactWidthThreshold
    }

    static func usesCompactHeight(for height: CGFloat) -> Bool {
        height < compactHeightThreshold
    }

    static func sidebarWidth(for width: CGFloat) -> CGFloat {
        min(
            max(width * sidebarWidthRatio, minimumSidebarWidth),
            maximumSidebarWidth
        )
    }
}

struct LaunchControlManagerView: View {
    private enum CompactPane: String, Hashable {
        case items
        case detail
    }

    @ObservedObject var controller: LaunchControlController
    @ObservedObject var searchFocusController: LaunchControlSettingsSearchFocusController
    private let localization: PluginLocalization

    @State private var scopeFilter: LaunchControlFilter = .user
    @State private var originFilter: LaunchControlOriginFilter = .all
    @State private var stateFilter: LaunchControlStateFilter = .all
    @State private var searchText = ""
    @State private var pendingAction: LaunchControlPendingAction?
    @State private var compactPane: CompactPane = .items
    @State private var noteDrafts: [String: String] = [:]
    @FocusState private var isSearchFocused: Bool

    init(
        controller: LaunchControlController,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        searchFocusController: LaunchControlSettingsSearchFocusController = .init()
    ) {
        self.controller = controller
        self.localization = localization
        self.searchFocusController = searchFocusController
    }

    var body: some View {
        GeometryReader { geometry in
            managerContent(
                availableWidth: geometry.size.width,
                availableHeight: geometry.size.height
            )
        }
        .onAppear {
            if controller.snapshot.items.isEmpty {
                controller.refresh()
            }
        }
        .onChange(of: filteredItems.map(\.id)) { _, visibleIDs in
            if let selectedID = controller.snapshot.selectedItemID,
               !visibleIDs.contains(selectedID) {
                compactPane = .items
            }
        }
        .onChange(of: searchFocusController.requestID) {
            isSearchFocused = true
        }
        .confirmationDialog(
            pendingAction?.confirmationTitle(localization: localization)
                ?? localization.string("manager.confirm.defaultTitle", defaultValue: "确认操作"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.buttonTitle(localization: localization), role: pendingAction.role) {
                    perform(pendingAction)
                    self.pendingAction = nil
                }
            }
            Button(localization.string("manager.confirm.cancel", defaultValue: "取消"), role: .cancel) {
                pendingAction = nil
            }
        } message: {
            if let pendingAction {
                Text(pendingAction.message(localization: localization))
            }
        }
    }

    private func managerContent(
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let usesCompactHeight = LaunchControlManagerLayout.usesCompactHeight(
            for: availableHeight
        )

        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if !usesCompactHeight || !hasScanActivity {
                summaryHeader(compact: usesCompactHeight)
            }
            toolbar(availableWidth: availableWidth)

            if let message = controller.snapshot.errorMessage {
                statusBanner(message: message, systemImage: "exclamationmark.triangle.fill", color: .orange)
            } else if let message = controller.snapshot.operationMessage {
                statusBanner(message: message, systemImage: "checkmark.circle.fill", color: .green)
            }

            primaryContent(availableWidth: availableWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)

            scanActivity(compact: usesCompactHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summaryHeader(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            FlowLayout(spacing: 8, rowSpacing: 8) {
                metric(localization.string("manager.metric.total", defaultValue: "总数"), value: controller.snapshot.items.count, color: .primary)

                if compact {
                    metric(localization.string("manager.metric.running", defaultValue: "运行中"), value: controller.snapshot.items.filter { $0.state == .running }.count, color: .green)
                    metric(localization.string("manager.metric.failed", defaultValue: "异常"), value: controller.snapshot.items.filter { $0.state == .failed }.count, color: .red)
                } else {
                    metric(localization.string("manager.metric.favorite", defaultValue: "关注"), value: controller.snapshot.items.filter(\.isFavorite).count, color: .yellow)
                    metric(localization.string("manager.metric.running", defaultValue: "运行中"), value: controller.snapshot.items.filter { $0.state == .running }.count, color: .green)
                    metric(localization.string("manager.metric.userCreated", defaultValue: "用户创建"), value: controller.snapshot.items.filter { $0.origin == .userCreated }.count, color: .orange)
                    metric(localization.string("manager.metric.appCreated", defaultValue: "应用创建"), value: controller.snapshot.items.filter { $0.origin == .thirdParty }.count, color: .blue)
                    metric(localization.string("manager.metric.failed", defaultValue: "异常"), value: controller.snapshot.items.filter { $0.state == .failed }.count, color: .red)
                }
            }

            if let target = controller.snapshot.currentScanTarget {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                    Text(URL(fileURLWithPath: target).lastPathComponent.isEmpty ? target : URL(fileURLWithPath: target).lastPathComponent)
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func toolbar(availableWidth: CGFloat) -> some View {
        let layout = LaunchControlManagerLayout.usesCompactPresentation(for: availableWidth)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))

        return layout {
            filterControls
            searchAndActionControls
        }
    }

    private var filterControls: some View {
        HStack(spacing: 10) {
            Picker(localization.string("manager.filter.scope", defaultValue: "范围"), selection: $scopeFilter) {
                ForEach(LaunchControlFilter.allCases) { filter in
                    Text(filter.title(localization: localization)).tag(filter)
                }
            }
            .labelsHidden()
            .frame(minWidth: 88, idealWidth: 112, maxWidth: .infinity)

            Picker(localization.string("manager.filter.origin", defaultValue: "来源"), selection: $originFilter) {
                ForEach(LaunchControlOriginFilter.allCases) { filter in
                    Text(filter.title(localization: localization)).tag(filter)
                }
            }
            .labelsHidden()
            .frame(minWidth: 88, idealWidth: 112, maxWidth: .infinity)

            Picker(localization.string("manager.filter.state", defaultValue: "状态"), selection: $stateFilter) {
                ForEach(LaunchControlStateFilter.allCases) { filter in
                    Text(filter.title(localization: localization)).tag(filter)
                }
            }
            .labelsHidden()
            .frame(minWidth: 88, idealWidth: 112, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var searchAndActionControls: some View {
        HStack(spacing: 10) {
            TextField(localization.string("manager.search.placeholder", defaultValue: "搜索 label、命令或路径"), text: $searchText)
                .focused($isSearchFocused)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 260, maxWidth: .infinity)

            Button {
                originFilter = originFilter == .favorite ? .all : .favorite
            } label: {
                Label(localization.string("manager.action.favoriteFilter", defaultValue: "关注"), systemImage: originFilter == .favorite ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)

            Button {
                controller.refresh()
            } label: {
                Label(
                    controller.snapshot.isRefreshing
                        ? localization.string("manager.action.refreshing", defaultValue: "刷新中")
                        : localization.string("manager.action.refresh", defaultValue: "刷新"),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(controller.snapshot.isRefreshing)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func primaryContent(availableWidth: CGFloat) -> some View {
        if LaunchControlManagerLayout.usesCompactPresentation(for: availableWidth) {
            compactPrimaryContent
        } else {
            HStack(alignment: .top, spacing: 0) {
                itemList
                    .frame(width: LaunchControlManagerLayout.sidebarWidth(for: availableWidth))

                Divider()

                detailPane
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var compactPrimaryContent: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $compactPane) {
                    Label(
                        localization.string("manager.list.title", defaultValue: "启动项"),
                        systemImage: "list.bullet"
                    )
                    .tag(CompactPane.items)

                    Label(
                        localization.string("manager.compact.detail", defaultValue: "详情"),
                        systemImage: "sidebar.right"
                    )
                    .tag(CompactPane.detail)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer(minLength: 0)
            }
            .padding(PluginSettingsTheme.Spacing.controlCluster)

            Divider()

            switch compactPane {
            case .items:
                itemList
            case .detail:
                detailPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pluginSettingsCardBackground(.standard)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localization.string("manager.list.title", defaultValue: "启动项"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Spacer()
                Text("\(filteredItems.count) / \(controller.snapshot.items.count)")
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(selection: selectedItemBinding) {
                ForEach(filteredItems) { item in
                    LaunchControlItemRow(
                        item: item,
                        localization: localization,
                        onFavoriteToggle: {
                            controller.setFavorite(!item.isFavorite, for: item)
                        }
                    )
                        .tag(item.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if controller.snapshot.isRefreshing && controller.snapshot.items.isEmpty {
                    ProgressView(localization.string("manager.list.scanning", defaultValue: "正在扫描"))
                        .controlSize(.small)
                } else if filteredItems.isEmpty {
                    ContentUnavailableView(
                        localization.string("manager.list.empty", defaultValue: "没有匹配项目"),
                        systemImage: "magnifyingglass"
                    )
                }
            }
        }
    }

    private var detailPane: some View {
        Group {
            if let item = selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailHeader(item)
                        actionBar(item)
                        LaunchControlNoteEditor(
                            item: item,
                            controller: controller,
                            localization: localization,
                            draft: noteDraftBinding(for: item)
                        )
                            .id(item.id)
                        keyFields(item)
                        rawPlist(item)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon, weight: .regular))
                .foregroundStyle(.secondary)
            Text(controller.snapshot.isRefreshing
                ? localization.string("manager.placeholder.loadingTitle", defaultValue: "正在读取启动项")
                : localization.string("manager.placeholder.title", defaultValue: "选择一个启动项")
            )
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
            Text(controller.snapshot.isRefreshing
                ? localization.string("manager.placeholder.loadingDescription", defaultValue: "左侧列表会随扫描进度逐步更新")
                : localization.string("manager.placeholder.description", defaultValue: "查看 plist 字段、运行状态和可用操作")
            )
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var hasScanActivity: Bool {
        controller.snapshot.isRefreshing || !controller.snapshot.scanLogEntries.isEmpty
    }

    @ViewBuilder
    private func scanActivity(compact: Bool) -> some View {
        if hasScanActivity {
            if compact {
                compactScanActivity
            } else {
                expandedScanActivity
            }
        }
    }

    private var compactScanActivity: some View {
        HStack(spacing: 8) {
            if controller.snapshot.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Text(localization.string("manager.scanActivity.title", defaultValue: "扫描进度"))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

            if let latestEntry = controller.snapshot.scanLogEntries.last {
                Text(latestEntry)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .pluginSettingsCardBackground(.standard)
    }

    private var expandedScanActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localization.string("manager.scanActivity.title", defaultValue: "扫描进度"))
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                if controller.snapshot.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(controller.snapshot.scanLogEntries.enumerated()), id: \.offset) { index, entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .frame(height: 88)
                .onChange(of: controller.snapshot.scanLogEntries.count) {
                    if let lastIndex = controller.snapshot.scanLogEntries.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .padding(10)
        .pluginSettingsCardBackground(.standard)
    }

    private var filteredItems: [LaunchControlItem] {
        controller.snapshot.items.filter { item in
            let scopeMatches = scopeFilter.scope.map { $0 == item.scope } ?? true
            let originMatches = originFilter.matches(item)
            let stateMatches = stateFilter.matches(item.state)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches: Bool
            if query.isEmpty {
                searchMatches = true
            } else {
                let haystack = [
                    item.label,
                    item.commandText(localization: localization),
                    item.plistURL.path,
                    item.origin.title(localization: localization),
                    item.triggerSummary(localization: localization),
                    item.note
                ].joined(separator: "\n")
                searchMatches = haystack.localizedCaseInsensitiveContains(query)
            }
            return scopeMatches && originMatches && stateMatches && searchMatches
        }
    }

    private var selectedItem: LaunchControlItem? {
        guard let selectedID = controller.snapshot.selectedItemID else {
            return nil
        }
        return filteredItems.first(where: { $0.id == selectedID })
    }

    private var selectedItemBinding: Binding<String?> {
        Binding(
            get: {
                guard let selectedID = controller.snapshot.selectedItemID,
                      filteredItems.contains(where: { $0.id == selectedID })
                else {
                    return nil
                }
                return selectedID
            },
            set: { itemID in
                controller.selectItem(id: itemID)
                if itemID != nil {
                    compactPane = .detail
                }
            }
        )
    }

    private func noteDraftBinding(for item: LaunchControlItem) -> Binding<String> {
        Binding(
            get: { noteDrafts[item.id] ?? item.note },
            set: { noteDrafts[item.id] = $0 }
        )
    }

    private func detailHeader(_ item: LaunchControlItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.origin == .system ? "lock.shield" : "powerplug")
                    .font(PluginSettingsTheme.Typography.pageTitle.weight(.semibold))
                    .foregroundStyle(item.origin == .system ? Color.secondary : Color.orange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.label)
                        .font(PluginSettingsTheme.Typography.pageTitle)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(item.plistURL.path)
                        .font(PluginSettingsTheme.Typography.controlLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Button {
                    controller.setFavorite(!item.isFavorite, for: item)
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                        .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(item.isFavorite
                    ? localization.string("manager.favorite.removeHelp", defaultValue: "取消关注")
                    : localization.string("manager.favorite.addHelp", defaultValue: "关注启动项")
                )
            }

            FlowLayout(spacing: 8, rowSpacing: 6) {
                badge(item.scope.title(localization: localization), color: .blue)
                badge(item.origin.title(localization: localization), color: item.origin == .system ? .gray : .orange)
                badge(item.statusText(localization: localization), color: item.state == .failed ? .red : .green)
                if !item.canManage {
                    badge(localization.string("manager.badge.readOnly", defaultValue: "只读"), color: .gray)
                }
            }
        }
    }

    private func actionBar(_ item: LaunchControlItem) -> some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            Button {
                controller.setFavorite(!item.isFavorite, for: item)
            } label: {
                Label(
                    item.isFavorite
                        ? localization.string("manager.action.unfavorite", defaultValue: "取消关注")
                        : localization.string("manager.action.favorite", defaultValue: "关注"),
                    systemImage: item.isFavorite ? "star.slash" : "star"
                )
            }

            Button {
                controller.openInFinder(item)
            } label: {
                Label(localization.string("manager.action.revealInFinder", defaultValue: "在 Finder 中显示"), systemImage: "finder")
            }

            if item.canManage {
                Button {
                    pendingAction = .bootstrap(item)
                } label: {
                    Label(LaunchControlManagedAction.bootstrap.title(localization: localization), systemImage: "tray.and.arrow.down")
                }
                .disabled(item.isLoaded)

                Button {
                    pendingAction = .bootout(item)
                } label: {
                    Label(LaunchControlManagedAction.bootout.title(localization: localization), systemImage: "tray.and.arrow.up")
                }
                .disabled(!item.isLoaded)

                Button {
                    pendingAction = item.isDisabled ? .enable(item) : .disable(item)
                } label: {
                    Label(
                        item.isDisabled
                            ? LaunchControlManagedAction.enable.title(localization: localization)
                            : LaunchControlManagedAction.disable.title(localization: localization),
                        systemImage: item.isDisabled ? "checkmark.circle" : "nosign"
                    )
                }

                Button {
                    pendingAction = item.state == .running ? .stop(item) : .start(item)
                } label: {
                    Label(
                        item.state == .running
                            ? LaunchControlManagedAction.stop.title(localization: localization)
                            : LaunchControlManagedAction.start.title(localization: localization),
                        systemImage: item.state == .running ? "stop.circle" : "play.circle"
                    )
                }
                .disabled(item.isDisabled)

                Button {
                    pendingAction = .restart(item)
                } label: {
                    Label(LaunchControlManagedAction.restart.title(localization: localization), systemImage: "arrow.clockwise.circle")
                }
                .disabled(item.isDisabled)
            }
        }
        .buttonStyle(.bordered)
    }

    private func keyFields(_ item: LaunchControlItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.string("manager.keyFields.title", defaultValue: "关键字段"))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

            fieldRow(
                "ProgramArguments",
                value: item.commandText(localization: localization),
                help: localization.string("manager.field.programArguments.help", defaultValue: "启动时执行的命令与参数。")
            )
            fieldRow(
                "RunAtLoad",
                value: item.runAtLoad ? "true" : "false",
                help: localization.string("manager.field.runAtLoad.help", defaultValue: "加载 LaunchAgent 后是否立即运行一次。")
            )
            fieldRow(
                "KeepAlive",
                value: item.keepAliveDescription ?? notSetText,
                help: localization.string("manager.field.keepAlive.help", defaultValue: "进程退出后是否按条件自动拉起。")
            )
            fieldRow(
                "StartInterval",
                value: item.startInterval.map { secondsText($0) } ?? notSetText,
                help: localization.string("manager.field.startInterval.help", defaultValue: "按固定秒数间隔触发。")
            )
            fieldRow(
                "StartCalendarInterval",
                value: item.startCalendarDescription ?? notSetText,
                help: localization.string("manager.field.startCalendar.help", defaultValue: "按日历时间触发。")
            )
            fieldRow(
                localization.string("manager.field.triggerSummary.title", defaultValue: "触发摘要"),
                value: item.triggerSummary(localization: localization),
                help: localization.string("manager.field.triggerSummary.help", defaultValue: "根据常见字段生成的可读说明。")
            )
        }
    }

    private func rawPlist(_ item: LaunchControlItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.string("manager.rawPlist.title", defaultValue: "原始 plist"))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

            ScrollView(.horizontal) {
                Text(item.rawPlist.isEmpty
                    ? localization.string("manager.rawPlist.unreadable", defaultValue: "无法以 UTF-8 显示原始内容")
                    : item.rawPlist
                )
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 180, maxHeight: 260)
            .pluginSettingsCardBackground(.recessed)
        }
    }

    private func fieldRow(_ title: String, value: String, help: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                fieldTitle(title)
                    .frame(width: 112, alignment: .leading)
                fieldValue(value, help: help)
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldTitle(title)
                fieldValue(value, help: help)
            }
        }
        .padding(10)
        .pluginSettingsCardBackground(.standard)
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func fieldValue(_ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(help)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
    }

    private func statusBanner(message: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: PluginSystemImage.resolvedName(systemImage))
                .foregroundStyle(color)
            Text(message)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous))
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(value)")
                .font(PluginSettingsTheme.Typography.pageTitle)
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .pluginSettingsCardBackground(.standard)
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func perform(_ action: LaunchControlPendingAction) {
        switch action {
        case let .bootstrap(item):
            controller.bootstrap(item)
        case let .bootout(item):
            controller.bootout(item)
        case let .enable(item):
            controller.enable(item)
        case let .disable(item):
            controller.disable(item)
        case let .start(item):
            controller.start(item)
        case let .stop(item):
            controller.stop(item)
        case let .restart(item):
            controller.restart(item)
        }
    }

    private var notSetText: String {
        localization.string("manager.field.notSet", defaultValue: "未设置")
    }

    private func secondsText(_ seconds: Int) -> String {
        localization.format("manager.seconds", defaultValue: "%d 秒", seconds)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(proposal: proposal, subviews: subviews)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.last.map { $0.y + $0.height } ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for row in rows(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func rows(proposal: ProposedViewSize, subviews: Subviews) -> [FlowRow] {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var y: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = currentItems.isEmpty ? size.width : currentWidth + spacing + size.width
            if nextWidth > maxWidth, !currentItems.isEmpty {
                rows.append(FlowRow(items: currentItems, y: y, width: currentWidth, height: currentHeight))
                y += currentHeight + rowSpacing
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            let x = currentItems.isEmpty ? 0 : currentWidth + spacing
            currentItems.append(FlowItem(index: index, x: x, size: size))
            currentWidth = currentItems.isEmpty ? size.width : x + size.width
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(items: currentItems, y: y, width: currentWidth, height: currentHeight))
        }

        return rows
    }
}

private struct FlowRow {
    let items: [FlowItem]
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct FlowItem {
    let index: Int
    let x: CGFloat
    let size: CGSize
}

private struct LaunchControlItemRow: View {
    let item: LaunchControlItem
    let localization: PluginLocalization
    let onFavoriteToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .lineLimit(1)
                    if item.origin == .userCreated {
                        Text(localization.string("manager.itemRow.userBadge", defaultValue: "用户"))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.orange)
                    }
                }

                Text(item.commandText(localization: localization))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(localization.format(
                    "manager.itemRow.scopeStatus",
                    defaultValue: "%@ · %@",
                    item.scope.title(localization: localization),
                    item.statusText(localization: localization)
                ))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onFavoriteToggle) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                    .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(item.isFavorite
                ? localization.string("manager.favorite.removeHelp", defaultValue: "取消关注")
                : localization.string("manager.favorite.addHelp", defaultValue: "关注启动项")
            )
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.state {
        case .running:
            return .green
        case .failed:
            return .red
        case .disabled:
            return .gray
        case .loaded:
            return .blue
        case .unloaded,
             .unknown:
            return .secondary
        }
    }
}

private enum LaunchControlPendingAction: Identifiable {
    case bootstrap(LaunchControlItem)
    case bootout(LaunchControlItem)
    case enable(LaunchControlItem)
    case disable(LaunchControlItem)
    case start(LaunchControlItem)
    case stop(LaunchControlItem)
    case restart(LaunchControlItem)

    var id: String {
        "\(actionName)-\(item.id)"
    }

    var item: LaunchControlItem {
        switch self {
        case let .bootstrap(item),
             let .bootout(item),
             let .enable(item),
             let .disable(item),
             let .start(item),
             let .stop(item),
             let .restart(item):
            return item
        }
    }

    var actionName: String {
        action.title()
    }

    func actionName(localization: PluginLocalization) -> String {
        action.title(localization: localization)
    }

    var action: LaunchControlManagedAction {
        switch self {
        case .bootstrap:
            return .bootstrap
        case .bootout:
            return .bootout
        case .enable:
            return .enable
        case .disable:
            return .disable
        case .start:
            return .start
        case .stop:
            return .stop
        case .restart:
            return .restart
        }
    }

    var buttonTitle: String {
        "\(actionName) \(item.label)"
    }

    func buttonTitle(localization: PluginLocalization) -> String {
        localization.format(
            "manager.confirm.buttonTitle",
            defaultValue: "%@ %@",
            actionName(localization: localization),
            item.label
        )
    }

    var confirmationTitle: String {
        confirmationTitle(localization: PluginLocalization(bundle: .main))
    }

    func confirmationTitle(localization: PluginLocalization) -> String {
        localization.format(
            "manager.confirm.title",
            defaultValue: "确认%@启动项？",
            actionName(localization: localization)
        )
    }

    var message: String {
        message(localization: PluginLocalization(bundle: .main))
    }

    func message(localization: PluginLocalization) -> String {
        localization.format(
            "manager.confirm.message",
            defaultValue: "%@\n%@\n\n此操作会调用 launchctl %@。用户级 LaunchAgent 通常可以恢复，但禁用、卸载或停止可能影响后台任务。",
            item.label,
            item.plistURL.path,
            actionName(localization: localization)
        )
    }

    var role: ButtonRole? {
        switch self {
        case .bootout,
             .disable,
             .stop:
            return .destructive
        case .bootstrap,
             .enable,
             .start,
             .restart:
            return nil
        }
    }
}

private struct LaunchControlNoteEditor: View {
    let item: LaunchControlItem
    let controller: LaunchControlController
    let localization: PluginLocalization
    @Binding var draft: String

    init(
        item: LaunchControlItem,
        controller: LaunchControlController,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        draft: Binding<String>
    ) {
        self.item = item
        self.controller = controller
        self.localization = localization
        _draft = draft
    }

    private var isDirty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != item.note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localization.string("manager.note.title", defaultValue: "备注"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Spacer()
                if isDirty {
                    Button(localization.string("manager.note.save", defaultValue: "保存")) {
                        controller.setNote(draft, for: item)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }

            TextEditor(text: $draft)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(6)
                .pluginSettingsCardBackground(.recessed)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(localization.string(
                            "manager.note.placeholder",
                            defaultValue: "为这个启动项添加本地备注（仅保存在本机，不写入 plist）。"
                        ))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
