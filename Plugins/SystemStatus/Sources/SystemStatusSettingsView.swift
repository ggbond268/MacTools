import AppKit
import MacToolsPluginKit
import SwiftUI

struct SystemStatusSettingsView: View {
    enum SectionKind {
        case panel
        case menuBar
    }

    @ObservedObject var controller: SystemStatusSettingsController
    @ObservedObject var viewModel: SystemStatusViewModel
    let localization: PluginLocalization
    let section: SectionKind

    @State private var isConfirmingMenuBarReset = false

    @ViewBuilder
    var body: some View {
        switch section {
        case .panel:
            panelSection
        case .menuBar:
            menuBarSection
        }
    }

    private var panelSection: some View {
        metricSection(
            systemName: "square.grid.2x2",
            title: localization.string("settings.panel.title", defaultValue: "组件面板"),
            description: localization.string(
                "settings.panel.description",
                defaultValue: "选择组件面板显示的内容，并拖拽调整顺序。"
            ),
            items: panelItems,
            listID: "panel",
            onVisibilityChange: controller.setPanelMetric(_:visible:),
            onMove: controller.movePanelMetric(_:toOffset:)
        )
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string("settings.menuBar.preview", defaultValue: "实时预览"))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.menuBar.builderDescription",
                            defaultValue: "每个指标最多选择两个数值。第一个显示在第二个之前或上方。点击或拖拽数值进行分配，拖拽指标可调整顺序。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                    HStack(spacing: 6) {
                        Text(localization.string(
                            "settings.menuBar.setAllMetricsTo",
                            defaultValue: "所有指标设为"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)

                        applyStyleButton(
                            .horizontal,
                            title: localization.string(
                                "settings.menuBarLayout.detailed",
                                defaultValue: "详细"
                            )
                        )
                        applyStyleButton(
                            .vertical,
                            title: localization.string(
                                "settings.menuBarLayout.compact",
                                defaultValue: "紧凑"
                            )
                        )
                        applyStyleButton(
                            .minimal,
                            title: localization.string(
                                "settings.menuBarLayout.minimal",
                                defaultValue: "极简"
                            )
                        )

                        if commonMenuBarStyle == nil {
                            Text(localization.string("settings.menuBarStyle.mixed", defaultValue: "混合"))
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.secondary)
                        }

                        Menu {
                            Button(localization.string(
                                "settings.menuBar.resetStylesAndLayout",
                                defaultValue: "重置样式与布局"
                            )) {
                                controller.resetMenuBarAppearances()
                            }
                            Button(role: .destructive) {
                                isConfirmingMenuBarReset = true
                            } label: {
                                Text(localization.string(
                                    "settings.menuBar.resetAll",
                                    defaultValue: "重置所有菜单栏设置…"
                                ))
                            }
                        } label: {
                            Label(
                                localization.string("settings.menuBar.reset", defaultValue: "重置"),
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                        .menuStyle(.button)
                        .controlSize(.small)
                    }
                    .fixedSize()
                }

                menuBarPreview
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            .pluginSettingsCardBackground(.standard)

            SystemStatusMenuBarMetricEditorView(
                items: menuBarItems,
                onVisibilityChange: controller.setMenuBarMetric(_:visible:),
                onMove: controller.moveMenuBarMetric(_:toOffset:),
                onValuesChange: controller.setMenuBarValues(_:values:),
                onStyleChange: controller.setMenuBarStyle(_:style:),
                onValueArrangementChange: controller.setMenuBarValueArrangement(_:arrangement:)
            )
        }
        .alert(
            localization.string("settings.menuBar.resetAll.confirmationTitle", defaultValue: "重置所有菜单栏设置？"),
            isPresented: $isConfirmingMenuBarReset
        ) {
            Button(localization.string("settings.menuBar.resetAll.cancel", defaultValue: "取消"), role: .cancel) {}
            Button(
                localization.string("settings.menuBar.resetAll.confirm", defaultValue: "重置"),
                role: .destructive
            ) {
                controller.resetMenuBarConfiguration()
            }
        } message: {
            Text(localization.string(
                "settings.menuBar.resetAll.confirmationMessage",
                defaultValue: "这会还原菜单栏指标的样式、数值、显示状态和顺序。"
            ))
        }
    }

    private var commonMenuBarStyle: SystemStatusMenuBarLayout? {
        guard let firstStyle = controller.configuration.menuBarItems.first?.style else {
            return nil
        }
        return controller.configuration.menuBarItems.dropFirst().allSatisfy { $0.style == firstStyle }
            ? firstStyle
            : nil
    }

    @ViewBuilder
    private func applyStyleButton(
        _ style: SystemStatusMenuBarLayout,
        title: String
    ) -> some View {
        if commonMenuBarStyle == style {
            Button(title) {
                controller.applyMenuBarStyleToAll(style)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(title) {
                controller.applyMenuBarStyleToAll(style)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var menuBarPreview: some View {
        let items = controller.configuration.menuBarItems.filter(\.isVisible)
        if items.isEmpty {
            Text(localization.string("settings.menuBar.previewEmpty", defaultValue: "选择指标后将在这里预览。"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .pluginSettingsCardBackground(.recessed)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                SystemStatusMenuBarPreviewView(
                    blocks: SystemStatusMenuBarMetricsFormatter.blocks(
                        snapshot: viewModel.snapshot,
                        items: items,
                        localization: localization
                    ),
                    layout: controller.configuration.menuBarLayout
                )
                .fixedSize()
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .pluginSettingsCardBackground(.recessed)
        }
    }

    private func metricSection(
        systemName _: String,
        title _: String,
        description _: String,
        items: [SystemStatusMetricPreferenceTableItem],
        listID: String,
        onVisibilityChange: @escaping (SystemStatusMetricKind, Bool) -> Void,
        onMove: @escaping (SystemStatusMetricKind, Int) -> Void
    ) -> some View {
        SystemStatusMetricPreferenceTableView(
            items: items,
            listID: listID,
            onVisibilityChange: onVisibilityChange,
            onMove: onMove
        )
        .frame(height: SystemStatusMetricPreferenceTableView.preferredHeight(for: items.count))
    }

    private var panelItems: [SystemStatusMetricPreferenceTableItem] {
        controller.configuration.panelItems.map {
            tableItem(
                preference: $0,
                description: panelDescription(for: $0.kind)
            )
        }
    }

    private var menuBarItems: [SystemStatusMetricPreferenceTableItem] {
        controller.configuration.menuBarItems.map {
            let kind = $0.kind
            let valueOptions = SystemStatusMenuBarValueKind.availableValues(for: kind).map {
                SystemStatusMenuBarValueOption(
                    kind: $0,
                    title: $0.title(localization: localization),
                    liveValue: liveMenuBarValue($0, for: kind)
                )
            }
            return tableItem(
                kind: kind,
                isVisible: $0.isVisible,
                description: menuBarDescription(for: kind),
                valueOptions: valueOptions,
                selectedValues: $0.values,
                style: $0.style,
                valueArrangement: $0.valueArrangement
            )
        }
    }

    private func tableItem(
        preference: SystemStatusMetricPreference,
        description: String
    ) -> SystemStatusMetricPreferenceTableItem {
        tableItem(
            kind: preference.kind,
            isVisible: preference.isVisible,
            description: description,
            valueOptions: [],
            selectedValues: []
        )
    }

    private func tableItem(
        kind: SystemStatusMetricKind,
        isVisible: Bool,
        description: String,
        valueOptions: [SystemStatusMenuBarValueOption],
        selectedValues: [SystemStatusMenuBarValueKind],
        style: SystemStatusMenuBarLayout = .horizontal,
        valueArrangement: SystemStatusMenuBarValueArrangement = .automatic
    ) -> SystemStatusMetricPreferenceTableItem {
        let title = kind.title(localization: localization)
        let visibilityActionTitle = isVisible
            ? localization.format(
                "settings.metric.visibility.hide",
                defaultValue: "隐藏%@",
                title
            )
            : localization.format(
                "settings.metric.visibility.show",
                defaultValue: "显示%@",
                title
            )

        return SystemStatusMetricPreferenceTableItem(
            kind: kind,
            title: title,
            description: description,
            iconName: kind.symbolName,
            iconTint: tint(for: kind),
            isVisible: isVisible,
            visibilityActionTitle: visibilityActionTitle,
            visibilityStateTitle: isVisible
                ? localization.string("settings.metric.visibility.visible", defaultValue: "已显示")
                : localization.string("settings.metric.visibility.hidden", defaultValue: "已隐藏"),
            valueOptions: valueOptions,
            selectedValues: selectedValues,
            style: style,
            styleTitle: localization.string("settings.menuBarStyle.title", defaultValue: "样式"),
            detailedStyleTitle: localization.string(
                "settings.menuBarLayout.detailed",
                defaultValue: "详细"
            ),
            compactStyleTitle: localization.string(
                "settings.menuBarLayout.compact",
                defaultValue: "紧凑"
            ),
            minimalStyleTitle: localization.string(
                "settings.menuBarLayout.minimal",
                defaultValue: "极简"
            ),
            valueArrangement: valueArrangement,
            valueArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.title",
                defaultValue: "数值布局"
            ),
            automaticArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.automatic",
                defaultValue: "自动"
            ),
            stackedArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.stacked",
                defaultValue: "上下排列"
            ),
            inlineArrangementTitle: localization.string(
                "settings.menuBarValueArrangement.inline",
                defaultValue: "并排显示"
            ),
            secondaryValueNoneTitle: localization.string(
                "settings.menuBarValue.none",
                defaultValue: "无第二数值"
            ),
            primaryValueTitle: localization.string(
                "settings.menuBarValue.first",
                defaultValue: "第一个数值"
            ),
            secondaryValueTitle: localization.string(
                "settings.menuBarValue.secondOptional",
                defaultValue: "第二个数值（可选）"
            ),
            availableValuesTitle: localization.string(
                "settings.menuBarValue.available",
                defaultValue: "可用数值"
            ),
            reorderAccessibilityTitle: localization.string(
                "settings.metric.reorderAccessibility",
                defaultValue: "拖拽调整顺序"
            )
        )
    }

    private func liveMenuBarValue(
        _ value: SystemStatusMenuBarValueKind,
        for kind: SystemStatusMetricKind
    ) -> String {
        if kind == .battery, value == .power, let batteryPowerDescription {
            return batteryPowerDescription
        }

        let item = SystemStatusMenuBarMetricPreference(
            kind: kind,
            isVisible: true,
            values: [value]
        )
        return SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: viewModel.snapshot,
            items: [item],
            localization: localization
        ).first?.values.first ?? "—"
    }

    private var batteryPowerDescription: String? {
        guard
            viewModel.snapshot.battery.isAvailable,
            let watts = viewModel.snapshot.battery.batteryPowerWatts,
            watts.isFinite
        else {
            return nil
        }

        let magnitude = abs(watts)
        guard magnitude >= 0.05 else {
            return SystemStatusFormatter.power(0)
        }

        if watts < 0 {
            return localization.format(
                "battery.chargePowerFormat",
                defaultValue: "充电 %@",
                SystemStatusFormatter.power(magnitude)
            )
        }

        return localization.format(
            "battery.dischargePowerFormat",
            defaultValue: "放电 %@",
            SystemStatusFormatter.power(magnitude)
        )
    }

    private func panelDescription(for kind: SystemStatusMetricKind) -> String {
        switch kind {
        case .cpu:
            return localization.string("settings.metric.cpu.panelDescription", defaultValue: "使用率、温度和功率")
        case .gpu:
            return localization.string("settings.metric.gpu.panelDescription", defaultValue: "使用率、温度和型号")
        case .network:
            return localization.string("settings.metric.network.panelDescription", defaultValue: "上传、下载和地址")
        case .disk:
            return localization.string("settings.metric.disk.panelDescription", defaultValue: "容量和读写速率")
        case .memory:
            return localization.string("settings.metric.memory.panelDescription", defaultValue: "内存和交换空间")
        case .battery:
            return localization.string("settings.metric.battery.panelDescription", defaultValue: "电量、健康度和温度")
        case .topProcesses:
            return localization.string("settings.metric.topProcesses.panelDescription", defaultValue: "CPU 占用最高的进程")
        }
    }

    private func menuBarDescription(for kind: SystemStatusMetricKind) -> String {
        switch kind {
        case .cpu:
            return localization.string("settings.metric.cpu.menuBarDescription", defaultValue: "显示 CPU 使用率")
        case .gpu:
            return localization.string("settings.metric.gpu.menuBarDescription", defaultValue: "显示 GPU 使用率")
        case .network:
            return localization.string("settings.metric.network.menuBarDescription", defaultValue: "显示上下行速率")
        case .disk:
            return localization.string("settings.metric.disk.menuBarDescription", defaultValue: "自定义容量和读写活动")
        case .memory:
            return localization.string("settings.metric.memory.menuBarDescription", defaultValue: "显示内存使用率")
        case .battery:
            return localization.string("settings.metric.battery.menuBarDescription", defaultValue: "显示电量")
        case .topProcesses:
            return localization.string("settings.metric.topProcesses.menuBarDescription", defaultValue: "不支持菜单栏显示")
        }
    }

    private func tint(for kind: SystemStatusMetricKind) -> Color {
        switch kind {
        case .cpu:
            return Color(nsColor: .systemGreen)
        case .gpu:
            return Color(nsColor: .systemPurple)
        case .network:
            return Color(nsColor: .systemCyan)
        case .disk:
            return Color(nsColor: .systemBlue)
        case .memory:
            return Color(nsColor: .systemOrange)
        case .battery:
            return Color(nsColor: .systemMint)
        case .topProcesses:
            return Color(nsColor: .systemGray)
        }
    }
}

private struct SystemStatusMenuBarPreviewView: NSViewRepresentable {
    let blocks: [SystemStatusMenuBarMetricBlock]
    let layout: SystemStatusMenuBarLayout

    func makeNSView(context: Context) -> SystemStatusMenuBarMetricsView {
        let view = SystemStatusMenuBarMetricsView()
        view.menuBarLayout = layout
        view.blocks = blocks
        return view
    }

    func updateNSView(_ view: SystemStatusMenuBarMetricsView, context: Context) {
        view.menuBarLayout = layout
        view.blocks = blocks
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SystemStatusMenuBarMetricsView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct SystemStatusMenuBarValueOption: Equatable, Identifiable {
    let kind: SystemStatusMenuBarValueKind
    let title: String
    let liveValue: String

    var id: String { kind.rawValue }
    var displayedTitle: String { "\(title) — \(liveValue)" }
}

struct SystemStatusMetricPreferenceTableItem: Equatable, Identifiable {
    let kind: SystemStatusMetricKind
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let isVisible: Bool
    let visibilityActionTitle: String
    let visibilityStateTitle: String
    let valueOptions: [SystemStatusMenuBarValueOption]
    let selectedValues: [SystemStatusMenuBarValueKind]
    let style: SystemStatusMenuBarLayout
    let styleTitle: String
    let detailedStyleTitle: String
    let compactStyleTitle: String
    let minimalStyleTitle: String
    let valueArrangement: SystemStatusMenuBarValueArrangement
    let valueArrangementTitle: String
    let automaticArrangementTitle: String
    let stackedArrangementTitle: String
    let inlineArrangementTitle: String
    let secondaryValueNoneTitle: String
    let primaryValueTitle: String
    let secondaryValueTitle: String
    let availableValuesTitle: String
    let reorderAccessibilityTitle: String

    var id: String { kind.rawValue }

    var appearanceSummary: String {
        "\(selectedStyleTitle) · \(selectedArrangementTitle)"
    }

    private var selectedStyleTitle: String {
        switch style {
        case .horizontal:
            return detailedStyleTitle
        case .vertical:
            return compactStyleTitle
        case .minimal:
            return minimalStyleTitle
        }
    }

    private var selectedArrangementTitle: String {
        switch valueArrangement {
        case .automatic:
            return automaticArrangementTitle
        case .stacked:
            return stackedArrangementTitle
        case .inline:
            return inlineArrangementTitle
        }
    }

    static func == (lhs: SystemStatusMetricPreferenceTableItem, rhs: SystemStatusMetricPreferenceTableItem) -> Bool {
        lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.description == rhs.description
            && lhs.iconName == rhs.iconName
            && lhs.isVisible == rhs.isVisible
            && lhs.visibilityActionTitle == rhs.visibilityActionTitle
            && lhs.visibilityStateTitle == rhs.visibilityStateTitle
            && lhs.valueOptions == rhs.valueOptions
            && lhs.selectedValues == rhs.selectedValues
            && lhs.style == rhs.style
            && lhs.styleTitle == rhs.styleTitle
            && lhs.detailedStyleTitle == rhs.detailedStyleTitle
            && lhs.compactStyleTitle == rhs.compactStyleTitle
            && lhs.minimalStyleTitle == rhs.minimalStyleTitle
            && lhs.valueArrangement == rhs.valueArrangement
            && lhs.valueArrangementTitle == rhs.valueArrangementTitle
            && lhs.automaticArrangementTitle == rhs.automaticArrangementTitle
            && lhs.stackedArrangementTitle == rhs.stackedArrangementTitle
            && lhs.inlineArrangementTitle == rhs.inlineArrangementTitle
            && lhs.secondaryValueNoneTitle == rhs.secondaryValueNoneTitle
            && lhs.primaryValueTitle == rhs.primaryValueTitle
            && lhs.secondaryValueTitle == rhs.secondaryValueTitle
            && lhs.availableValuesTitle == rhs.availableValuesTitle
            && lhs.reorderAccessibilityTitle == rhs.reorderAccessibilityTitle
    }
}

enum SystemStatusMenuBarValueSlot: Int, CaseIterable, Sendable {
    case primary
    case secondary
}

enum SystemStatusMenuBarSlotAssignment {
    static func assigning(
        _ value: SystemStatusMenuBarValueKind,
        to slot: SystemStatusMenuBarValueSlot,
        in selectedValues: [SystemStatusMenuBarValueKind]
    ) -> [SystemStatusMenuBarValueKind] {
        var values = Array(selectedValues.prefix(2))
        guard !values.isEmpty else {
            return [value]
        }

        let targetIndex = slot.rawValue
        if let sourceIndex = values.firstIndex(of: value) {
            guard sourceIndex != targetIndex else {
                return values
            }
            guard targetIndex < values.count else {
                return values
            }
            values.swapAt(sourceIndex, targetIndex)
            return values
        }

        if targetIndex < values.count {
            values[targetIndex] = value
        } else {
            values.append(value)
        }
        return values
    }

    static func clearingSecondary(
        in selectedValues: [SystemStatusMenuBarValueKind]
    ) -> [SystemStatusMenuBarValueKind] {
        Array(selectedValues.prefix(1))
    }
}

enum SystemStatusMenuBarEditorDragPayload {
    private static let metricPrefix = "system-status-metric"
    private static let valuePrefix = "system-status-value"

    static func metric(_ kind: SystemStatusMetricKind) -> String {
        "\(metricPrefix):\(kind.rawValue)"
    }

    static func metric(from payload: String) -> SystemStatusMetricKind? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(metricPrefix) else {
            return nil
        }
        return SystemStatusMetricKind(rawValue: String(parts[1]))
    }

    static func value(
        _ value: SystemStatusMenuBarValueKind,
        metric: SystemStatusMetricKind
    ) -> String {
        "\(valuePrefix):\(metric.rawValue):\(value.rawValue)"
    }

    static func value(
        from payload: String,
        metric: SystemStatusMetricKind
    ) -> SystemStatusMenuBarValueKind? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            parts[0] == Substring(valuePrefix),
            parts[1] == Substring(metric.rawValue)
        else {
            return nil
        }
        return SystemStatusMenuBarValueKind(rawValue: String(parts[2]))
    }
}

private struct SystemStatusMenuBarMetricEditorView: View {
    let items: [SystemStatusMetricPreferenceTableItem]
    let onVisibilityChange: (SystemStatusMetricKind, Bool) -> Void
    let onMove: (SystemStatusMetricKind, Int) -> Void
    let onValuesChange: (SystemStatusMetricKind, [SystemStatusMenuBarValueKind]) -> Void
    let onStyleChange: (SystemStatusMetricKind, SystemStatusMenuBarLayout) -> Void
    let onValueArrangementChange: (
        SystemStatusMetricKind,
        SystemStatusMenuBarValueArrangement
    ) -> Void

    @State private var expandedKind: SystemStatusMetricKind?
    @State private var selectedSlots: [SystemStatusMetricKind: SystemStatusMenuBarValueSlot] = [:]

    var body: some View {
        SystemStatusMenuBarMetricEditorTableView(
            items: items,
            expandedKind: expandedKind,
            selectedSlots: $selectedSlots,
            onToggleExpansion: toggleExpansion,
            onVisibilityChange: onVisibilityChange,
            onMove: onMove,
            onValuesChange: onValuesChange,
            onStyleChange: onStyleChange,
            onValueArrangementChange: onValueArrangementChange
        )
        .frame(maxWidth: .infinity)
    }

    private func toggleExpansion(_ kind: SystemStatusMetricKind) {
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedKind = expandedKind == kind ? nil : kind
        }
    }
}

enum SystemStatusMenuBarEditorLayout {
    static let collapsedRowHeight: CGFloat = 66
    static let expandedSingleGridRowHeight: CGFloat = 192
    static let valueMinimumWidth: CGFloat = 132
    static let valueHeight: CGFloat = 28
    static let valueSpacing: CGFloat = 7

    // Match the adaptive grid without measuring live SwiftUI rows on every sample.
    static func expandedHeight(width: CGFloat, valueCount: Int) -> CGFloat {
        let availableWidth = max(width - PluginSettingsTheme.Spacing.rowHorizontal * 2, 0)
        let columns = max(Int((availableWidth + valueSpacing) / (valueMinimumWidth + valueSpacing)), 1)
        let rows = max((valueCount + columns - 1) / columns, 1)
        return expandedSingleGridRowHeight + CGFloat(rows - 1) * (valueHeight + valueSpacing)
    }
}

struct SystemStatusMenuBarMetricEditorRow: View {
    let item: SystemStatusMetricPreferenceTableItem
    let isExpanded: Bool
    @Binding var selectedSlot: SystemStatusMenuBarValueSlot
    let onToggleExpansion: () -> Void
    let onVisibilityChange: (Bool) -> Void
    let onValuesChange: ([SystemStatusMenuBarValueKind]) -> Void
    let onStyleChange: (SystemStatusMenuBarLayout) -> Void
    let onValueArrangementChange: (SystemStatusMenuBarValueArrangement) -> Void

    private let slotWidth: CGFloat = 146
    private let secondaryClearButtonWidth: CGFloat = 16
    private let secondaryClearButtonSpacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                metricIdentity

                HStack(spacing: 6) {
                    slot(.primary)
                    secondarySlotRegion
                }
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    onVisibilityChange(!item.isVisible)
                } label: {
                    Image(systemName: item.isVisible ? "eye" : "eye.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.isVisible ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(item.visibilityActionTitle)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.visibilityStateTitle)

                Button(action: onToggleExpansion) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(item.title)
                .accessibilityValue(isExpanded ? "1" : "0")

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
                    .help(item.reorderAccessibilityTitle)
                    .accessibilityLabel(item.reorderAccessibilityTitle)
            }

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Text(item.styleTitle)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                        Picker(
                            item.styleTitle,
                            selection: Binding(
                                get: { item.style },
                                set: { style in
                                    onStyleChange(style)
                                }
                            )
                        ) {
                            Text(item.detailedStyleTitle)
                                .tag(SystemStatusMenuBarLayout.horizontal)
                            Text(item.compactStyleTitle)
                                .tag(SystemStatusMenuBarLayout.vertical)
                            Text(item.minimalStyleTitle)
                                .tag(SystemStatusMenuBarLayout.minimal)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 250)
                    }

                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Text(item.valueArrangementTitle)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                        Picker(
                            item.valueArrangementTitle,
                            selection: Binding(
                                get: { item.valueArrangement },
                                set: { arrangement in
                                    onValueArrangementChange(arrangement)
                                }
                            )
                        ) {
                            Text(item.automaticArrangementTitle)
                                .tag(SystemStatusMenuBarValueArrangement.automatic)
                            Text(item.stackedArrangementTitle)
                                .tag(SystemStatusMenuBarValueArrangement.stacked)
                            Text(item.inlineArrangementTitle)
                                .tag(SystemStatusMenuBarValueArrangement.inline)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 250)
                    }

                    Text(item.availableValuesTitle)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(minimum: SystemStatusMenuBarEditorLayout.valueMinimumWidth),
                            spacing: SystemStatusMenuBarEditorLayout.valueSpacing
                        )],
                        alignment: .leading,
                        spacing: SystemStatusMenuBarEditorLayout.valueSpacing
                    ) {
                        ForEach(item.valueOptions) { option in
                            valueChip(option)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.065 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isExpanded ? 0.10 : 0.055), lineWidth: 1)
        )
    }

    private var metricIdentity: some View {
        Button(action: onToggleExpansion) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(item.iconTint.opacity(0.14))
                    Image(systemName: item.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.iconTint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.appearanceSummary)
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func slot(_ slot: SystemStatusMenuBarValueSlot) -> some View {
        let option = option(for: slot)
        HStack(spacing: 2) {
            Button {
                selectedSlot = slot
                if !isExpanded {
                    onToggleExpansion()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slotTitle(slot))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let option {
                        HStack(spacing: 5) {
                            Text(option.title)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(option.liveValue)
                                .font(.system(.caption, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium))
                    } else {
                        Text(item.secondaryValueNoneTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: slotWidth, height: 42, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            selectedSlot == slot && isExpanded
                                ? Color.accentColor.opacity(0.9)
                                : Color.primary.opacity(0.10),
                            style: StrokeStyle(
                                lineWidth: selectedSlot == slot && isExpanded ? 1.5 : 1,
                                dash: option == nil ? [4, 3] : []
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .dropDestination(for: String.self) { payloads, _ in
                guard let value = payloads.compactMap({
                    SystemStatusMenuBarEditorDragPayload.value(from: $0, metric: item.kind)
                }).first else {
                    return false
                }
                selectedSlot = slot
                assign(value, to: slot)
                return true
            }
            .accessibilityLabel(slotTitle(slot))
            .accessibilityValue(option?.displayedTitle ?? item.secondaryValueNoneTitle)

            if slot == .secondary, option != nil {
                Button {
                    onValuesChange(
                        SystemStatusMenuBarSlotAssignment.clearingSecondary(
                            in: item.selectedValues
                        )
                    )
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 24)
                }
                .buttonStyle(.plain)
                .help(item.secondaryValueNoneTitle)
                .accessibilityLabel(item.secondaryValueNoneTitle)
            }
        }
    }

    private var secondarySlotRegion: some View {
        slot(.secondary)
            .frame(
                width: slotWidth + secondaryClearButtonSpacing + secondaryClearButtonWidth,
                alignment: .leading
            )
    }

    private func valueChip(_ option: SystemStatusMenuBarValueOption) -> some View {
        let assignedSlot = item.selectedValues.firstIndex(of: option.kind)
        return Button {
            assign(option.kind, to: selectedSlot)
        } label: {
            HStack(spacing: 6) {
                if let assignedSlot {
                    Text(String(assignedSlot + 1))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16, height: 16)
                        .background(Color.accentColor.opacity(0.13), in: Circle())
                }
                Text(option.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(option.liveValue)
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(minHeight: SystemStatusMenuBarEditorLayout.valueHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(assignedSlot == nil ? Color.primary.opacity(0.04) : Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        assignedSlot == nil ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.25),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .draggable(SystemStatusMenuBarEditorDragPayload.value(option.kind, metric: item.kind))
        .help(option.displayedTitle)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.liveValue)
    }

    private func assign(
        _ value: SystemStatusMenuBarValueKind,
        to slot: SystemStatusMenuBarValueSlot
    ) {
        onValuesChange(
            SystemStatusMenuBarSlotAssignment.assigning(
                value,
                to: slot,
                in: item.selectedValues
            )
        )
    }

    private func option(for slot: SystemStatusMenuBarValueSlot) -> SystemStatusMenuBarValueOption? {
        guard item.selectedValues.indices.contains(slot.rawValue) else {
            return nil
        }
        let kind = item.selectedValues[slot.rawValue]
        return item.valueOptions.first(where: { $0.kind == kind })
    }

    private func slotTitle(_ slot: SystemStatusMenuBarValueSlot) -> String {
        slot == .primary ? item.primaryValueTitle : item.secondaryValueTitle
    }
}

struct SystemStatusMenuBarMetricEditorTableView: NSViewRepresentable {
    static let collapsedRowHeight = SystemStatusMenuBarEditorLayout.collapsedRowHeight
    static let rowSpacing: CGFloat = 6
    static let verticalContentInset: CGFloat = 6
    private static let dragType = NSPasteboard.PasteboardType(
        "com.ggbond.mactools.system-status.menu-bar-metric-editor"
    )

    let items: [SystemStatusMetricPreferenceTableItem]
    let expandedKind: SystemStatusMetricKind?
    @Binding var selectedSlots: [SystemStatusMetricKind: SystemStatusMenuBarValueSlot]
    let onToggleExpansion: (SystemStatusMetricKind) -> Void
    let onVisibilityChange: (SystemStatusMetricKind, Bool) -> Void
    let onMove: (SystemStatusMetricKind, Int) -> Void
    let onValuesChange: (SystemStatusMetricKind, [SystemStatusMenuBarValueKind]) -> Void
    let onStyleChange: (SystemStatusMetricKind, SystemStatusMenuBarLayout) -> Void
    let onValueArrangementChange: (
        SystemStatusMetricKind,
        SystemStatusMenuBarValueArrangement
    ) -> Void

    private func expandedRowHeight(width: CGFloat) -> CGFloat {
        guard let item = items.first(where: { $0.kind == expandedKind }) else { return Self.collapsedRowHeight }
        return SystemStatusMenuBarEditorLayout.expandedHeight(width: width, valueCount: item.valueOptions.count)
    }

    private func preferredHeight(width: CGFloat) -> CGFloat {
        guard !items.isEmpty else {
            return Self.verticalContentInset * 2
        }
        let collapsedRowsHeight = CGFloat(items.count) * Self.collapsedRowHeight
        let expandedHeight = expandedRowHeight(width: width) - Self.collapsedRowHeight
        let spacing = CGFloat(max(items.count - 1, 0)) * Self.rowSpacing
        return collapsedRowsHeight + expandedHeight + spacing + Self.verticalContentInset * 2
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: preferredHeight(width: width))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SystemStatusMetricPreferenceScrollView()
        scrollView.onContentWidthChange = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.syncLayout(in: scrollView)
        }
        scrollView.contentView = SystemStatusMetricPreferenceClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.verticalContentInset,
            left: 0,
            bottom: Self.verticalContentInset,
            right: 0
        )

        let tableView = PluginSettingsReorderTableView(dragType: Self.dragType)
        tableView.rowHeight = Self.collapsedRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metric-editor"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.syncLayout(in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncLayout(in: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SystemStatusMenuBarMetricEditorTableView
        weak var tableView: NSTableView?
        private var lastItems: [SystemStatusMetricPreferenceTableItem] = []
        private var lastOrder: [SystemStatusMetricKind] = []
        private var lastExpandedKind: SystemStatusMetricKind?
        private var lastContentWidth: CGFloat = 0
        private var lastExpandedHeight: CGFloat = 0
        private var isDragging = false

        init(parent: SystemStatusMenuBarMetricEditorTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard parent.items.indices.contains(row) else {
                return SystemStatusMenuBarMetricEditorTableView.collapsedRowHeight
            }
            return parent.items[row].kind == parent.expandedKind
                ? parent.expandedRowHeight(width: tableView.bounds.width)
                : SystemStatusMenuBarMetricEditorTableView.collapsedRowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("SystemStatusMenuBarMetricEditorCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil)
                as? SystemStatusMenuBarMetricHostingCellView)
                ?? SystemStatusMenuBarMetricHostingCellView(frame: .zero)
            cell.identifier = identifier
            configure(cell, row: row)
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard parent.items.indices.contains(row) else {
                return nil
            }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(
                SystemStatusMenuBarEditorDragPayload.metric(parent.items[row].kind),
                forType: SystemStatusMenuBarMetricEditorTableView.dragType
            )
            return pasteboardItem
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            isDragging = true
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            lastOrder = []
            tableView.reloadData()
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard draggedKind(from: info.draggingPasteboard) != nil else {
                return []
            }
            tableView.setDropRow(
                min(max(row, 0), parent.items.count),
                dropOperation: .above
            )
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let kind = draggedKind(from: info.draggingPasteboard) else {
                return false
            }
            parent.onMove(kind, min(max(row, 0), parent.items.count))
            return true
        }

        func syncLayout(in scrollView: NSScrollView) {
            guard let tableView, !isDragging else {
                return
            }

            let contentWidth = max(scrollView.contentSize.width, 1)
            let expandedHeight = parent.expandedRowHeight(width: contentWidth)
            let rowContentHeight = parent.preferredHeight(width: contentWidth)
                - SystemStatusMenuBarMetricEditorTableView.verticalContentInset * 2
            tableView.frame = NSRect(
                x: 0,
                y: 0,
                width: contentWidth,
                height: rowContentHeight
            )

            let order = parent.items.map(\.kind)
            let layoutChanged = order != lastOrder
                || parent.expandedKind != lastExpandedKind
                || contentWidth.rounded(.toNearestOrAwayFromZero) != lastContentWidth
                || expandedHeight != lastExpandedHeight

            if layoutChanged {
                tableView.reloadData()
                tableView.noteNumberOfRowsChanged()
            } else if parent.items != lastItems {
                updateVisibleCells(in: tableView)
            }

            lastItems = parent.items
            lastOrder = order
            lastExpandedKind = parent.expandedKind
            lastExpandedHeight = expandedHeight
            lastContentWidth = contentWidth.rounded(.toNearestOrAwayFromZero)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func updateVisibleCells(in tableView: NSTableView) {
            for row in parent.items.indices {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? SystemStatusMenuBarMetricHostingCellView else {
                    continue
                }
                configure(cell, row: row)
            }
        }

        private func configure(_ cell: SystemStatusMenuBarMetricHostingCellView, row: Int) {
            guard parent.items.indices.contains(row) else {
                return
            }
            let item = parent.items[row]
            cell.configure(
                rootView: SystemStatusMenuBarMetricEditorRow(
                    item: item,
                    isExpanded: item.kind == parent.expandedKind,
                    selectedSlot: Binding(
                        get: { self.parent.selectedSlots[item.kind] ?? .primary },
                        set: { self.parent.selectedSlots[item.kind] = $0 }
                    ),
                    onToggleExpansion: { [weak self] in
                        self?.parent.onToggleExpansion(item.kind)
                    },
                    onVisibilityChange: { [weak self] isVisible in
                        self?.parent.onVisibilityChange(item.kind, isVisible)
                    },
                    onValuesChange: { [weak self] values in
                        self?.parent.onValuesChange(item.kind, values)
                    },
                    onStyleChange: { [weak self] style in
                        self?.parent.onStyleChange(item.kind, style)
                    },
                    onValueArrangementChange: { [weak self] arrangement in
                        self?.parent.onValueArrangementChange(item.kind, arrangement)
                    }
                )
            )
        }

        private func draggedKind(from pasteboard: NSPasteboard) -> SystemStatusMetricKind? {
            guard
                let payload = pasteboard.string(
                    forType: SystemStatusMenuBarMetricEditorTableView.dragType
                ),
                let kind = SystemStatusMenuBarEditorDragPayload.metric(from: payload),
                parent.items.contains(where: { $0.kind == kind })
            else {
                return nil
            }
            return kind
        }
    }
}

private final class SystemStatusMenuBarMetricHostingCellView: NSTableCellView {
    private var hostingView: NSHostingView<SystemStatusMenuBarMetricEditorRow>?

    func configure(rootView: SystemStatusMenuBarMetricEditorRow) {
        if let hostingView {
            hostingView.rootView = rootView
            return
        }

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.hostingView = hostingView
    }
}

struct SystemStatusMetricPreferenceTableView: NSViewRepresentable {
    static let rowHeight: CGFloat = 58
    static let rowSpacing: CGFloat = 6
    static let verticalContentInset: CGFloat = 6
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.system-status.metric-preference")

    let items: [SystemStatusMetricPreferenceTableItem]
    let listID: String
    let onVisibilityChange: (SystemStatusMetricKind, Bool) -> Void
    let onMove: (SystemStatusMetricKind, Int) -> Void

    static func preferredHeight(for itemCount: Int) -> CGFloat {
        let visibleItemCount = max(itemCount, 1)
        let spacing = CGFloat(max(itemCount - 1, 0)) * rowSpacing
        return CGFloat(visibleItemCount) * rowHeight + spacing + verticalContentInset * 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SystemStatusMetricPreferenceScrollView()
        scrollView.contentView = SystemStatusMetricPreferenceClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.verticalContentInset,
            left: 0,
            bottom: Self.verticalContentInset,
            right: 0
        )

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.verticalMotionCanBeginDrag = true
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([Self.dragType])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metric"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        syncLayout(in: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        syncLayout(in: scrollView, coordinator: context.coordinator)
    }

    private func syncLayout(in scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = coordinator.tableView, !coordinator.isDragging else {
            return
        }

        let contentHeight = Self.preferredHeight(for: items.count)
        let contentWidth = max(scrollView.contentSize.width, 1)
        let signature = SystemStatusMetricPreferenceTableSignature(
            items: items,
            listID: listID,
            contentWidth: contentWidth
        )

        guard coordinator.lastSignature != signature else {
            return
        }

        coordinator.lastSignature = signature
        tableView.reloadData()
        tableView.noteNumberOfRowsChanged()
        tableView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SystemStatusMetricPreferenceTableView
        weak var tableView: NSTableView?
        fileprivate var lastSignature: SystemStatusMetricPreferenceTableSignature?
        fileprivate var isDragging = false

        init(parent: SystemStatusMetricPreferenceTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            SystemStatusMetricPreferenceTableView.rowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("SystemStatusMetricPreferenceCell")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SystemStatusMetricPreferenceCellView)
                ?? SystemStatusMetricPreferenceCellView(frame: .zero)
            view.identifier = identifier

            let item = parent.items[row]
            view.configure(
                item: item,
                onVisibilityChange: { [weak self] isVisible in
                    self?.parent.onVisibilityChange(item.kind, isVisible)
                }
            )
            return view
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(
                "\(parent.listID):\(parent.items[row].kind.rawValue)",
                forType: SystemStatusMetricPreferenceTableView.dragType
            )
            return pasteboardItem
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            isDragging = true
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            lastSignature = nil
            tableView.reloadData()
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard draggedKind(from: info.draggingPasteboard) != nil else {
                return []
            }

            tableView.setDropRow(min(max(row, 0), parent.items.count), dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let kind = draggedKind(from: info.draggingPasteboard) else {
                return false
            }

            parent.onMove(kind, min(max(row, 0), parent.items.count))
            return true
        }

        private func draggedKind(from pasteboard: NSPasteboard) -> SystemStatusMetricKind? {
            guard
                let payload = pasteboard.string(forType: SystemStatusMetricPreferenceTableView.dragType),
                payload.hasPrefix("\(parent.listID):")
            else {
                return nil
            }

            let rawValue = String(payload.dropFirst(parent.listID.count + 1))
            let kind = SystemStatusMetricKind(rawValue: rawValue)
            guard let kind, parent.items.contains(where: { $0.kind == kind }) else {
                return nil
            }
            return kind
        }
    }
}

private struct SystemStatusMetricPreferenceTableSignature: Equatable {
    let rows: [SystemStatusMetricPreferenceTableItem]
    let listID: String
    let contentWidth: CGFloat

    init(
        items: [SystemStatusMetricPreferenceTableItem],
        listID: String,
        contentWidth: CGFloat
    ) {
        self.rows = items
        self.listID = listID
        self.contentWidth = contentWidth.rounded(.toNearestOrAwayFromZero)
    }
}

private final class SystemStatusMetricPreferenceScrollView: NSScrollView {
    var onContentWidthChange: ((NSScrollView) -> Void)?
    private var lastReportedWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = contentSize.width
        guard width != lastReportedWidth else { return }
        lastReportedWidth = width
        onContentWidthChange?(self)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class SystemStatusMetricPreferenceClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin = .zero
        return bounds
    }
}

final class SystemStatusMetricPreferenceCellView: NSTableCellView {
    private let containerView = NSView()
    private let iconBackgroundView = NSView()
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let visibilityButton = NSButton(title: "", target: nil, action: nil)
    private let handleImageView = NSImageView()
    private var visibilityHandler: ((Bool) -> Void)?
    private var isVisible = false

    var reorderAccessibilityLabel: String? {
        handleImageView.accessibilityLabel()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
        configureStyles()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: SystemStatusMetricPreferenceTableItem,
        onVisibilityChange: @escaping (Bool) -> Void
    ) {
        visibilityHandler = onVisibilityChange
        titleLabel.stringValue = item.title
        descriptionLabel.stringValue = item.description
        iconImageView.image = NSImage(
            systemSymbolName: item.iconName,
            accessibilityDescription: item.title
        )
        iconImageView.contentTintColor = NSColor(item.iconTint)
        iconBackgroundView.layer?.backgroundColor = NSColor(item.iconTint.opacity(0.14)).cgColor
        isVisible = item.isVisible
        visibilityButton.image = NSImage(
            systemSymbolName: isVisible ? "eye" : "eye.slash",
            accessibilityDescription: nil
        )
        visibilityButton.contentTintColor = isVisible ? .controlAccentColor : .secondaryLabelColor
        toolTip = item.title
        visibilityButton.toolTip = item.visibilityActionTitle
        visibilityButton.setAccessibilityLabel(item.title)
        visibilityButton.setAccessibilityValue(item.visibilityStateTitle)
        visibilityButton.setAccessibilityHelp(item.visibilityActionTitle)
        handleImageView.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: item.reorderAccessibilityTitle
        )
        handleImageView.setAccessibilityLabel(item.reorderAccessibilityTitle)
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        containerView.wantsLayer = true
        iconBackgroundView.wantsLayer = true

        addSubview(containerView)
        containerView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(descriptionLabel)
        containerView.addSubview(visibilityButton)
        containerView.addSubview(handleImageView)
    }

    private func configureStyles() {
        containerView.layer?.cornerRadius = 12
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        iconBackgroundView.layer?.cornerRadius = 10

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 1

        visibilityButton.setButtonType(.momentaryPushIn)
        visibilityButton.title = ""
        visibilityButton.imagePosition = .imageOnly
        visibilityButton.bezelStyle = .inline
        visibilityButton.isBordered = false
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityToggle(_:))

        handleImageView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        handleImageView.contentTintColor = .secondaryLabelColor
        handleImageView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    }

    private func configureLayout() {
        [
            containerView,
            iconBackgroundView,
            iconImageView,
            titleLabel,
            descriptionLabel,
            visibilityButton,
            handleImageView
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBackgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            iconBackgroundView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 30),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 30),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),

            visibilityButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            visibilityButton.trailingAnchor.constraint(equalTo: handleImageView.leadingAnchor, constant: -12),
            visibilityButton.widthAnchor.constraint(equalToConstant: 22),
            visibilityButton.heightAnchor.constraint(equalToConstant: 22),

            handleImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            handleImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            handleImageView.widthAnchor.constraint(equalToConstant: 16),
            handleImageView.heightAnchor.constraint(equalToConstant: 16)
        ].compactMap { $0 })
    }

    @objc
    private func handleVisibilityToggle(_ sender: NSButton) {
        visibilityHandler?(!isVisible)
    }
}
