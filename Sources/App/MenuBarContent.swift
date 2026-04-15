import AppKit
import SwiftUI

enum MenuBarPanelLayout {
    static let baseWidth: CGFloat = 312
    static let secondaryPanelWidth: CGFloat = 220
    static let panelSpacing: CGFloat = 12
    static let outerPadding: CGFloat = 8
    static let navigationRowHeight: CGFloat = 58

    static var surfaceWidth: CGFloat {
        baseWidth - (outerPadding * 2)
    }

    static func width(for panelItems: [PluginPanelItem]) -> CGFloat {
        baseWidth
    }
}

private enum FeatureRowLayout {
    static let iconSize: CGFloat = 28
    static let rowSpacing: CGFloat = 10
    static let detailLeadingInset: CGFloat = iconSize + rowSpacing
}

struct MenuBarContent: View {
    private struct DeferredPanelSwitchAction {
        let pluginID: String
        let isOn: Bool
    }

    @StateObject private var secondaryPanelController = SecondaryPanelController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var pluginHost: PluginHost
    @State private var deferredPanelSwitchAction: DeferredPanelSwitchAction?
    @State private var selectedNavigationRowFrame: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            featureCards
            settingsCard
        }
        .padding(MenuBarPanelLayout.outerPadding)
        .frame(width: MenuBarPanelLayout.width(for: pluginHost.panelItems), alignment: .leading)
        .background(
            MenuWindowAccessor { window in
                secondaryPanelController.hostWindow = window
                syncSecondaryPanelWindow()
            }
        )
        .animation(.easeOut(duration: 0.18), value: attachedSecondaryPanelItemID)
        .onChange(of: attachedSecondaryPanelItemID) {
            syncSecondaryPanelWindow()
        }
        .onChange(of: selectedNavigationRowFrame) {
            syncSecondaryPanelWindow()
        }
        .onReceive(pluginHost.$settingsPresentationRequestCount.dropFirst()) { _ in
            presentSettings()
        }
        .onDisappear {
            flushDeferredPanelSwitchActionIfNeeded()
            secondaryPanelController.hide()
        }
    }

    private func presentSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
        dismiss()
    }

    private func handlePanelSwitchChange(_ newValue: Bool, for item: PluginPanelItem) {
        switch item.menuActionBehavior {
        case .keepPresented:
            pluginHost.setSwitchValue(newValue, for: item.id)
        case .dismissBeforeHandling:
            deferredPanelSwitchAction = DeferredPanelSwitchAction(
                pluginID: item.id,
                isOn: newValue
            )
            dismiss()
        }
    }

    private func flushDeferredPanelSwitchActionIfNeeded() {
        guard let deferredPanelSwitchAction else {
            return
        }

        self.deferredPanelSwitchAction = nil
        pluginHost.setSwitchValue(
            deferredPanelSwitchAction.isOn,
            for: deferredPanelSwitchAction.pluginID
        )
    }

    private func syncSecondaryPanelWindow() {
        guard
            let panelItem = attachedSecondaryPanelItem,
            let panel = panelItem.detail?.secondaryPanel,
            let anchorRect = selectedNavigationRowFrame
        else {
            secondaryPanelController.hide()
            return
        }

        secondaryPanelController.show(
            panel: panel,
            pluginID: panelItem.id,
            anchorRect: anchorRect,
            onSelectionChange: { controlID, optionID in
                pluginHost.setPanelSelectionValue(optionID, controlID: controlID, for: panelItem.id)
            },
            onNavigationSelectionChange: { controlID, optionID in
                pluginHost.setPanelNavigationSelectionValue(optionID, controlID: controlID, for: panelItem.id)
            },
            onDateChange: { controlID, date in
                pluginHost.setPanelDateValue(date, controlID: controlID, for: panelItem.id)
            }
        )
    }

    private var attachedSecondaryPanelItemID: String? {
        attachedSecondaryPanelItem?.id
    }

    private var attachedSecondaryPanelItem: PluginPanelItem? {
        pluginHost.panelItems.first { item in
            guard item.detail?.secondaryPanel != nil else {
                return false
            }

            if item.controlStyle == .disclosure {
                return item.isExpanded
            }

            return true
        }
    }

    private var featureCards: some View {
        VStack(spacing: 8) {
            ForEach(pluginHost.panelItems) { item in
                FeatureRowView(
                    item: item,
                    tracksSelectedNavigationRow: attachedSecondaryPanelItemID == item.id,
                    isOn: Binding(
                        get: { pluginHost.isSwitchOn(for: item.id) },
                        set: { newValue in
                            handlePanelSwitchChange(newValue, for: item)
                        }
                    ),
                    onDisclosureToggle: { isExpanded in
                        pluginHost.setDisclosureExpanded(isExpanded, for: item.id)
                    },
                    onSelectionChange: { controlID, optionID in
                        pluginHost.setPanelSelectionValue(optionID, controlID: controlID, for: item.id)
                    },
                    onNavigationSelectionChange: { controlID, optionID in
                        pluginHost.setPanelNavigationSelectionValue(optionID, controlID: controlID, for: item.id)
                    },
                    onSelectedNavigationRowFrameChange: { frame in
                        if attachedSecondaryPanelItemID == item.id {
                            selectedNavigationRowFrame = frame
                        }
                    },
                    onDateChange: { controlID, date in
                        pluginHost.setPanelDateValue(date, controlID: controlID, for: item.id)
                    }
                )
            }
        }
        .padding(6)
        .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Button {
                presentSettings()
            } label: {
                MenuActionRowLabel(title: "设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                MenuActionRowLabel(title: "退出", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct FeatureRowView: View {
    let item: PluginPanelItem
    let tracksSelectedNavigationRow: Bool
    @Binding var isOn: Bool
    let onDisclosureToggle: (Bool) -> Void
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onSelectedNavigationRowFrameChange: (CGRect?) -> Void
    let onDateChange: (String, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: detailToDisplay == nil ? 0 : 12) {
            switch item.controlStyle {
            case .switch:
                rowHeader
            case .disclosure:
                Button {
                    onDisclosureToggle(!item.isExpanded)
                } label: {
                    rowHeader
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }

            if let detail = detailToDisplay {
                PluginPanelDetailView(
                    detail: detail,
                    showsSecondaryPanel: false,
                    onSelectionChange: onSelectionChange,
                    onNavigationSelectionChange: onNavigationSelectionChange,
                    onSelectedNavigationRowFrameChange: tracksSelectedNavigationRow ? onSelectedNavigationRowFrameChange : { _ in },
                    onDateChange: onDateChange
                )
                .padding(.leading, FeatureRowLayout.detailLeadingInset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.001))
        )
        .contentShape(Rectangle())
        .help(item.helpText)
    }

    private var rowHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(item.iconTint.opacity(0.14))

                Image(systemName: item.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.iconTint)
            }
            .frame(width: FeatureRowLayout.iconSize, height: FeatureRowLayout.iconSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(item.description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.descriptionTone == .error ? Color.red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.helpText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch item.controlStyle {
            case .switch:
                Toggle(String(), isOn: $isOn)
                    .labelsHidden()
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .disabled(!item.isEnabled)
            case .disclosure:
                Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detailToDisplay: PluginPanelDetail? {
        guard let detail = item.detail else {
            return nil
        }

        if item.controlStyle == .disclosure && !item.isExpanded {
            return nil
        }

        return detail
    }
}

private struct PluginPanelDetailView: View {
    let detail: PluginPanelDetail
    let showsSecondaryPanel: Bool
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onSelectedNavigationRowFrameChange: (CGRect?) -> Void
    let onDateChange: (String, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(detail.primaryControls) { control in
                panelControl(control)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func panelControl(_ control: PluginPanelControl) -> some View {
        switch control.kind {
        case .segmented:
            Picker(
                String(),
                selection: Binding(
                    get: { control.selectedOptionID ?? "" },
                    set: { newValue in
                        onSelectionChange(control.id, newValue)
                    }
                )
            ) {
                ForEach(control.options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!control.isEnabled)
        case .datePicker:
            switch control.datePickerStyle ?? .compact {
            case .compact:
                DatePicker(
                    String(),
                    selection: Binding(
                        get: { control.dateValue ?? Date() },
                        set: { newValue in
                            onDateChange(control.id, newValue)
                        }
                    ),
                    in: (control.minimumDate ?? Date())...,
                    displayedComponents: control.displayedComponents ?? [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .disabled(!control.isEnabled)
            case .dateTimeCard:
                DateTimeCardPicker(
                    selection: Binding(
                        get: { control.dateValue ?? Date() },
                        set: { newValue in
                            onDateChange(control.id, newValue)
                        }
                    ),
                    minimumDate: control.minimumDate ?? Date(),
                    isEnabled: control.isEnabled
                )
            }
        case .selectList:
            SelectListControl(
                control: control,
                onSelect: { optionID in
                    onSelectionChange(control.id, optionID)
                }
            )
        case .navigationList:
            NavigationListControl(
                control: control,
                onSelect: { optionID in
                    onNavigationSelectionChange(control.id, optionID)
                },
                onSelectedRowFrameChange: onSelectedNavigationRowFrameChange
            )
        }
    }
}

private struct SelectListControl: View {
    let control: PluginPanelControl
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = control.sectionTitle {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.bottom, 2)
            }

            VStack(spacing: 0) {
                ForEach(control.options) { option in
                    SelectListRow(
                        title: option.title,
                        isSelected: option.id == control.selectedOptionID,
                        isEnabled: control.isEnabled,
                        action: { onSelect(option.id) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SelectListRow: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard isInteractive else {
                return
            }

            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isInteractive && isHovered ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }

    private var isInteractive: Bool {
        isEnabled && !isSelected
    }
}

private struct NavigationListControl: View {
    let control: PluginPanelControl
    let onSelect: (String) -> Void
    let onSelectedRowFrameChange: (CGRect?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(control.options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)

                            if let subtitle = option.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(option.id == control.selectedOptionID ? 1 : 0.35)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(minHeight: MenuBarPanelLayout.navigationRowHeight)
                    .background(
                        option.id == control.selectedOptionID
                            ? Color.accentColor.opacity(0.10)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!control.isEnabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if option.id == control.selectedOptionID {
                        SelectedRowFrameReader(onFrameChange: onSelectedRowFrameChange)
                    }
                }
            }
        }
    }
}

private struct SecondarySlidingPanel: View {
    let title: String
    let controls: [PluginPanelControl]
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onDateChange: (String, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            PluginPanelDetailView(
                detail: PluginPanelDetail(primaryControls: controls, secondaryPanel: nil),
                showsSecondaryPanel: false,
                onSelectionChange: onSelectionChange,
                onNavigationSelectionChange: onNavigationSelectionChange,
                onSelectedNavigationRowFrameChange: { _ in },
                onDateChange: onDateChange
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private final class SecondaryPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SecondaryPanelController: ObservableObject {
    // 侧栏窗口必须保持与 MenuBarExtra popover 的 *兄弟* 关系，而不是 child window。
    //
    // 背景：`NSWindow.addChildWindow(_:, ordered:)` 会把父子窗口的 key-status 绑成
    // 同一个 focus group，导致父窗口在用户点击外部时收不到 `didResignKeyNotification`。
    // 而 `MenuBarExtra(.window)` 的 dismiss 流程（由 SwiftUI 私有的
    // `WindowMenuBarExtraBehavior` 实现）正是监听 popover 的 `didResignKey` 才触发
    // 收起。所以一旦把本侧栏以 child window 形式挂上去，popover 永远不会自己关。
    //
    // 解决：改为独立（sibling）NSPanel，不调用 `addChildWindow`。位置由
    // `anchorRect` 直接算出；level 调到 `.popUpMenu` 以保证 Z 序高于 popover；
    // 生命周期由 SwiftUI 视图的 `.onDisappear` → `hide()` 级联清理。
    //
    // 参考：
    // - MenuBarExtraAccess 源码（对 MenuBarExtraWindow 做 didResignKey 观察）
    //   https://github.com/orchetect/MenuBarExtraAccess
    // - Apple Feedback FB11984872（无法程序化关闭 window-style MenuBarExtra）
    // - CocoaDev 「HowCanChildWindowBeKey」https://cocoadev.github.io/HowCanChildWindowBeKey/

    weak var hostWindow: NSWindow?
    private var panelWindow: SecondaryPanelWindow?

    func show(
        panel: PluginPanelSecondaryPanel,
        pluginID: String,
        anchorRect: CGRect,
        onSelectionChange: @escaping (String, String) -> Void,
        onNavigationSelectionChange: @escaping (String, String) -> Void,
        onDateChange: @escaping (String, Date) -> Void
    ) {
        guard let hostWindow else { return }
        // MenuWindowAccessor.updateNSView 会在 .onDisappear 之后仍派发 async 回调，
        // 可能在 hide() 之后再次触发 show()。popover 被 dismiss 时 hostWindow 的
        // isVisible 已经变为 false，以此拦截竞态导致的侧栏重新展示。
        guard hostWindow.isVisible else { return }

        let rootView = SecondarySlidingPanel(
            title: panel.title,
            controls: panel.controls,
            onSelectionChange: onSelectionChange,
            onNavigationSelectionChange: onNavigationSelectionChange,
            onDateChange: onDateChange
        )
        .frame(width: MenuBarPanelLayout.secondaryPanelWidth)

        let hostingView = NSHostingView(rootView: rootView)
        let fittingSize = hostingView.fittingSize
        let width = MenuBarPanelLayout.secondaryPanelWidth
        let height = max(fittingSize.height, 160)
        let origin = CGPoint(
            x: anchorRect.maxX + MenuBarPanelLayout.panelSpacing,
            y: anchorRect.maxY - height
        )
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))

        let panelWindow = panelWindow ?? makePanel()
        panelWindow.contentView = hostingView
        panelWindow.setFrame(frame, display: true)
        // 运行时把 panel level 动态对齐到 hostWindow.level + 1，保证 Z 序高于 popover。
        // MenuBarExtra popover 的 level 是 SwiftUI 私有实现细节，不能硬编码。
        panelWindow.level = NSWindow.Level(rawValue: hostWindow.level.rawValue + 1)
        panelWindow.orderFrontRegardless()
        self.panelWindow = panelWindow
    }

    func hide() {
        guard let panelWindow else { return }
        panelWindow.orderOut(nil)
        self.panelWindow = nil
    }

    private func makePanel() -> SecondaryPanelWindow {
        let panel = SecondaryPanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 必须保持为 false：在 `.nonactivatingPanel` + 菜单栏 app 的组合下，
        // `hidesOnDeactivate = true` 会让这个 panel 在 orderFront 之后陷入
        // 「NSWindow.isVisible 仍为 true 但实际像素不上屏」的半死状态，侧栏完全
        // 看不见（被 popover 右侧的其他 app 窗口内容透出来）。
        // 侧栏生命周期已经由 MenuBarContent.onDisappear → SecondaryPanelController.hide()
        // 负责级联清理，不需要 hidesOnDeactivate 作为兜底。
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct MenuWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

private struct SelectedRowFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            updateFrame(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            updateFrame(for: nsView)
        }
    }

    private func updateFrame(for view: NSView) {
        guard let window = view.window else {
            onFrameChange(nil)
            return
        }

        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        onFrameChange(rectOnScreen)
    }
}

private struct DateTimeCardPicker: View {
    @Binding var selection: Date
    let minimumDate: Date
    let isEnabled: Bool

    var body: some View {
        DatePicker(
            String(),
            selection: Binding(
                get: { sanitizedDate(selection) },
                set: { newValue in
                    selection = sanitizedDate(newValue)
                }
            ),
            in: minimumDate...,
            displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!isEnabled)
        .environment(\.locale, .current)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.6)
    }

    private func sanitizedDate(_ candidate: Date) -> Date {
        max(candidate, minimumDate)
    }
}

private struct MenuActionRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 38,
            maxHeight: 38,
            alignment: .leading
        )
        .contentShape(Rectangle())
    }
}
