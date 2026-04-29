import AppKit
import SwiftUI

enum MenuBarPanelLayout {
    static let baseWidth: CGFloat = 296
    static let secondaryPanelWidth: CGFloat = 220
    static let panelSpacing: CGFloat = 12
    static let outerPadding: CGFloat = 4
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
    static let detailControlHorizontalPadding: CGFloat = 10
    static let detailLeadingInset: CGFloat = iconSize + rowSpacing - detailControlHorizontalPadding
}

private enum MenuBarHoverStyle {
    static let cornerRadius: CGFloat = 12
    static let fill = Color.primary.opacity(0.06)
    static let inset: CGFloat = 1
    static let navigationCornerRadius: CGFloat = 10
    static let navigationFill = Color.primary.opacity(0.10)
    static let navigationSelectedFill = Color.primary.opacity(0.13)
}

@MainActor
final class HoverSecondaryPanelCoordinator: ObservableObject {
    struct Activation: Equatable, Hashable {
        let pluginID: String
        let controlID: String
        let optionID: String
    }

    @Published private(set) var activeActivation: Activation?
    @Published private(set) var selectedRowFrame: CGRect?

    var onDismissRequest: ((Activation) -> Void)?

    private let dismissDelay: Duration
    private let activationDelay: Duration?
    private var activationTask: Task<Void, Never>?
    private var pendingActivation: Activation?
    private var dismissTask: Task<Void, Never>?
    private var isPanelHovered = false
    private var rowFrames: [Activation: CGRect] = [:]

    init(
        dismissDelay: Duration = .milliseconds(160),
        activationDelay: Duration? = .milliseconds(120)
    ) {
        self.dismissDelay = dismissDelay
        self.activationDelay = activationDelay
    }

    func hoverBegan(
        pluginID: String,
        controlID: String,
        optionID: String
    ) {
        let activation = Activation(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )

        cancelDismissal()
        isPanelHovered = false

        guard activeActivation != activation else {
            selectedRowFrame = rowFrames[activation]
            return
        }

        cancelPendingActivation()

        guard let activationDelay else {
            activate(activation)
            return
        }

        pendingActivation = activation
        activationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: activationDelay)
            guard !Task.isCancelled else {
                return
            }

            self?.activate(activation)
        }
    }

    private func activate(_ activation: Activation) {
        cancelPendingActivation()
        activeActivation = activation
        selectedRowFrame = rowFrames[activation]
    }

    func hoverEnded(
        pluginID: String,
        controlID: String,
        optionID: String
    ) {
        let activation = Activation(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )

        if pendingActivation == activation {
            cancelPendingActivation()
            scheduleDismissIfNeeded(expectedActivation: activeActivation)
            return
        }

        scheduleDismissIfNeeded(expectedActivation: activation)
    }

    func setPanelHovered(_ isHovered: Bool) {
        isPanelHovered = isHovered

        if isHovered {
            cancelDismissal()
        } else {
            scheduleDismissIfNeeded(expectedActivation: activeActivation)
        }
    }

    func updateRowFrame(_ frame: CGRect?, for activation: Activation) {
        if let frame {
            rowFrames[activation] = frame
        } else {
            rowFrames.removeValue(forKey: activation)
        }

        guard activeActivation == activation else {
            return
        }

        selectedRowFrame = frame
    }

    func dismissImmediately() {
        cancelPendingActivation()
        dismissInternal(notify: true)
    }

    private func scheduleDismissIfNeeded(expectedActivation: Activation?) {
        cancelDismissal()

        guard
            let expectedActivation,
            activeActivation == expectedActivation
        else {
            return
        }

        dismissTask = Task { [dismissDelay] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else {
                return
            }

            dismissIfNeeded(expectedActivation)
        }
    }

    private func dismissIfNeeded(_ expectedActivation: Activation) {
        guard
            activeActivation == expectedActivation,
            !isPanelHovered
        else {
            return
        }

        dismissInternal(notify: true)
    }

    private func dismissInternal(notify: Bool) {
        cancelDismissal()

        guard let activation = activeActivation else {
            selectedRowFrame = nil
            isPanelHovered = false
            return
        }

        activeActivation = nil
        selectedRowFrame = nil
        isPanelHovered = false

        if notify {
            onDismissRequest?(activation)
        }
    }

    private func cancelDismissal() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func cancelPendingActivation() {
        activationTask?.cancel()
        activationTask = nil
        pendingActivation = nil
    }
}

struct MenuBarContent: View {
    static let diskCleanWindowID = "disk-clean"
    static let diskCleanOpenDetailsActionID = DiskCleanPlugin.ControlID.openDetails

    private struct DeferredPanelSwitchAction {
        let pluginID: String
        let isOn: Bool
    }

    private struct DeferredActionInvocation {
        let pluginID: String
        let controlID: String
    }

    @StateObject private var secondaryPanelController = SecondaryPanelController()
    @StateObject private var hoverCoordinator = HoverSecondaryPanelCoordinator()

    @ObservedObject var pluginHost: PluginHost
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDiskCleanDetails: () -> Void
    @State private var deferredPanelSwitchAction: DeferredPanelSwitchAction?
    @State private var deferredActionInvocation: DeferredActionInvocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            featureCards
            Divider()
            settingsCard
        }
        .padding(MenuBarPanelLayout.outerPadding)
        .frame(width: MenuBarPanelLayout.width(for: pluginHost.panelItems), alignment: .leading)
        .background(
            MenuWindowAccessor { window in
                secondaryPanelController.setHostWindow(window)
                syncSecondaryPanelWindow()
            }
        )
        .onAppear {
            hoverCoordinator.onDismissRequest = { activation in
                pluginHost.clearPanelNavigationSelection(
                    controlID: activation.controlID,
                    for: activation.pluginID
                )
            }

            secondaryPanelController.onHostWindowDismissRequest = {
                hoverCoordinator.dismissImmediately()
            }
        }
        .animation(.easeOut(duration: 0.18), value: activeSecondaryPanelSignature)
        .onChange(of: activeSecondaryPanelSignature) {
            syncSecondaryPanelWindow()
        }
        .onChange(of: hoverCoordinator.selectedRowFrame) {
            syncSecondaryPanelWindow()
        }
        .onChange(of: hoverCoordinator.activeActivation) {
            syncSecondaryPanelWindow()
        }
        .onReceive(pluginHost.$settingsPresentationRequestCount.dropFirst()) { _ in
            presentSettings()
        }
        .onDisappear {
            flushDeferredPanelSwitchActionIfNeeded()
            flushDeferredActionInvocationIfNeeded()
            hoverCoordinator.dismissImmediately()
            hoverCoordinator.onDismissRequest = nil
            secondaryPanelController.onHostWindowDismissRequest = nil
            secondaryPanelController.setHostWindow(nil)
        }
    }

    private func presentSettings() {
        onOpenSettings()
        onDismiss()
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
            onDismiss()
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

    private func handleActionInvoke(
        controlID: String,
        for item: PluginPanelItem,
        behavior: PluginMenuActionBehavior
    ) {
        if isDiskCleanOpenDetailsAction(pluginID: item.id, controlID: controlID) {
            deferredActionInvocation = DeferredActionInvocation(
                pluginID: item.id,
                controlID: controlID
            )
            onDismiss()
            return
        }

        switch behavior {
        case .keepPresented:
            pluginHost.invokePanelAction(controlID: controlID, for: item.id)
        case .dismissBeforeHandling:
            // 先收 popover 再执行，避免动作打开新窗口时菜单还浮在屏上挡视线。
            deferredActionInvocation = DeferredActionInvocation(
                pluginID: item.id,
                controlID: controlID
            )
            onDismiss()
        }
    }

    private func flushDeferredActionInvocationIfNeeded() {
        guard let deferred = deferredActionInvocation else {
            return
        }

        self.deferredActionInvocation = nil

        if isDiskCleanOpenDetailsAction(pluginID: deferred.pluginID, controlID: deferred.controlID) {
            presentDiskCleanDetails()
            return
        }

        pluginHost.invokePanelAction(
            controlID: deferred.controlID,
            for: deferred.pluginID
        )
    }

    private func isDiskCleanOpenDetailsAction(pluginID: String, controlID: String) -> Bool {
        pluginID == Self.diskCleanWindowID && controlID == Self.diskCleanOpenDetailsActionID
    }

    private func presentDiskCleanDetails() {
        onOpenDiskCleanDetails()
    }

    private func syncSecondaryPanelWindow() {
        guard
            let activation = hoverCoordinator.activeActivation,
            let panelItem = pluginHost.panelItems.first(where: { $0.id == activation.pluginID }),
            let panel = panelItem.detail?.secondaryPanel(
                controlID: activation.controlID,
                optionID: activation.optionID
            ),
            let anchorRect = hoverCoordinator.selectedRowFrame
        else {
            secondaryPanelController.hide()
            return
        }

        secondaryPanelController.show(
            panel: panel,
            anchorRect: anchorRect,
            onSelectionChange: { controlID, optionID in
                pluginHost.setPanelSelectionValue(optionID, controlID: controlID, for: panelItem.id)
            },
            onNavigationSelectionChange: { controlID, optionID in
                pluginHost.setPanelNavigationSelectionValue(optionID, controlID: controlID, for: panelItem.id)
            },
            onDateChange: { controlID, date in
                pluginHost.setPanelDateValue(date, controlID: controlID, for: panelItem.id)
            },
            onHoverChange: handleSecondaryPanelHoverChange,
            onSliderChange: { controlID, value, phase in
                pluginHost.setPanelSliderValue(
                    value,
                    controlID: controlID,
                    for: panelItem.id,
                    phase: phase
                )
            }
        )
    }

    private func handleNavigationHoverChange(
        pluginID: String,
        controlID: String,
        optionID: String,
        isHovering: Bool
    ) {
        if isHovering {
            hoverCoordinator.hoverBegan(
                pluginID: pluginID,
                controlID: controlID,
                optionID: optionID
            )
            return
        }

        hoverCoordinator.hoverEnded(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )
    }

    private func handleSecondaryPanelHoverChange(_ isHovering: Bool) {
        hoverCoordinator.setPanelHovered(isHovering)
    }

    private var activeSecondaryPanelSignature: String? {
        guard
            let activation = hoverCoordinator.activeActivation,
            let panelItem = pluginHost.panelItems.first(where: { $0.id == activation.pluginID }),
            let panel = panelItem.detail?.secondaryPanel(
                controlID: activation.controlID,
                optionID: activation.optionID
            )
        else {
            return nil
        }

        let controlIDs = panel.controls.map(\.id).joined(separator: ",")
        return "\(activation.pluginID)|\(activation.optionID)|\(panel.title)|\(controlIDs)"
    }

    private var featureCards: some View {
        VStack(spacing: 8) {
            ForEach(pluginHost.panelItems) { item in
                FeatureRowView(
                    item: item,
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
                    onNavigationHoverChange: { controlID, optionID, isHovering in
                        handleNavigationHoverChange(
                            pluginID: item.id,
                            controlID: controlID,
                            optionID: optionID,
                            isHovering: isHovering
                        )
                    },
                    onNavigationRowFrameChange: { controlID, optionID, frame in
                        hoverCoordinator.updateRowFrame(
                            frame,
                            for: HoverSecondaryPanelCoordinator.Activation(
                                pluginID: item.id,
                                controlID: controlID,
                                optionID: optionID
                            )
                        )
                    },
                    onDateChange: { controlID, date in
                        pluginHost.setPanelDateValue(date, controlID: controlID, for: item.id)
                    },
                    onSliderChange: { controlID, value, phase in
                        pluginHost.setPanelSliderValue(
                            value,
                            controlID: controlID,
                            for: item.id,
                            phase: phase
                        )
                    },
                    onActionInvoke: { controlID, behavior in
                        handleActionInvoke(
                            controlID: controlID,
                            for: item,
                            behavior: behavior
                        )
                    }
                )
            }
        }
        .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Button {
                presentSettings()
            } label: {
                MenuActionRowLabel(title: "设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                MenuActionRowLabel(title: "退出", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
    }
}

struct FeatureRowView: View {
    let item: PluginPanelItem
    @Binding var isOn: Bool
    let onDisclosureToggle: (Bool) -> Void
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onNavigationHoverChange: (String, String, Bool) -> Void
    let onNavigationRowFrameChange: (String, String, CGRect?) -> Void
    let onDateChange: (String, Date) -> Void
    @State private var isHovered = false
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void
    let onActionInvoke: (String, PluginMenuActionBehavior) -> Void

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
                    onNavigationHoverChange: onNavigationHoverChange,
                    onNavigationRowFrameChange: onNavigationRowFrameChange,
                    onDateChange: onDateChange,
                    onSliderChange: onSliderChange,
                    onActionInvoke: onActionInvoke
                )
                .padding(.leading, FeatureRowLayout.detailLeadingInset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous)
                .inset(by: MenuBarHoverStyle.inset)
                .fill(item.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous))
        .onHover { isHovered = $0 }
        .help(item.helpText)
    }

    private var rowHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.08))

                Image(systemName: item.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
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
    let onNavigationHoverChange: (String, String, Bool) -> Void
    let onNavigationRowFrameChange: (String, String, CGRect?) -> Void
    let onDateChange: (String, Date) -> Void
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void
    let onActionInvoke: (String, PluginMenuActionBehavior) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(detail.primaryControls) { control in
                if control.showsLeadingDivider {
                    Divider()
                        .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
                }

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
                onHoverChange: { optionID, isHovering in
                    onNavigationHoverChange(control.id, optionID, isHovering)
                },
                onRowFrameChange: { optionID, frame in
                    onNavigationRowFrameChange(control.id, optionID, frame)
                }
            )
        case .slider:
            SliderControl(
                control: control,
                onChange: { value, phase in
                    onSliderChange(control.id, value, phase)
                }
            )
        case .actionRow:
            ActionRowControl(
                control: control,
                onInvoke: {
                    onActionInvoke(control.id, control.actionBehavior)
                }
            )
        }
    }
}

private struct ActionRowControl: View {
    let control: PluginPanelControl
    let onInvoke: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard control.isEnabled else { return }
            onInvoke()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: control.actionIconSystemName ?? "arrow.up.right.square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)

                Text(control.actionTitle ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                    .inset(by: MenuBarHoverStyle.inset)
                    .fill(control.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(!control.isEnabled)
        .onHover { isHovered = $0 }
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
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .inset(by: MenuBarHoverStyle.inset)
                    .fill(isInteractive && isHovered ? MenuBarHoverStyle.fill : Color.clear)
            }
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
    let onHoverChange: (String, Bool) -> Void
    let onRowFrameChange: (String, CGRect?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(control.options) { option in
                NavigationListRow(
                    title: option.title,
                    subtitle: option.subtitle,
                    isSelected: option.id == control.selectedOptionID,
                    isEnabled: control.isEnabled,
                    action: { onSelect(option.id) },
                    onHoverChange: { isHovering in
                        onHoverChange(option.id, isHovering)
                    },
                    onRowFrameChange: { frame in
                        onRowFrameChange(option.id, frame)
                    }
                )
            }
        }
    }
}

private struct NavigationListRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    let onHoverChange: (Bool) -> Void
    let onRowFrameChange: (CGRect?) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard isInteractive else {
                return
            }

            action()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isSelected ? 1 : (isHovered ? 0.55 : 0.35))
            }
            .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
            .padding(.vertical, 9)
            .frame(minHeight: MenuBarPanelLayout.navigationRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                    .inset(by: MenuBarHoverStyle.inset)
                    .fill(backgroundFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            NavigationRowFrameReader(
                onFrameChange: onRowFrameChange
            )
        }
        .onDisappear {
            onHoverChange(false)
            onRowFrameChange(nil)
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
    }

    private var isInteractive: Bool {
        isEnabled && !isSelected
    }

    private var backgroundFill: Color {
        if isSelected {
            return MenuBarHoverStyle.navigationSelectedFill
        }

        if isHovered && isEnabled {
            return MenuBarHoverStyle.navigationFill
        }

        return .clear
    }
}

private struct SliderControl: View {
    let control: PluginPanelControl
    let onChange: (Double, PluginPanelAction.SliderPhase) -> Void

    @State private var localValue = 0.0
    @State private var isEditing = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if control.sectionTitle != nil || control.valueLabel != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title = control.sectionTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if let valueLabel = control.valueLabel {
                        Text(valueLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                brightnessGlyph(systemName: "sun.min.fill", size: 13)

                Slider(
                    value: Binding(
                        get: { isEditing ? localValue : (control.sliderValue ?? localValue) },
                        set: { newValue in
                            let snappedValue = snappedSliderValue(for: newValue)
                            localValue = snappedValue
                            onChange(snappedValue, .changed)
                        }
                    ),
                    in: control.sliderBounds ?? 0...1,
                    onEditingChanged: { isEditing in
                        self.isEditing = isEditing

                        if isEditing {
                            localValue = control.sliderValue ?? localValue
                        } else {
                            onChange(localValue, .ended)
                        }
                    }
                )
                .labelsHidden()
                .disabled(!control.isEnabled)
                .tint(Color(nsColor: .controlAccentColor))
                .accessibilityLabel(control.sectionTitle ?? "显示器亮度")

                brightnessGlyph(systemName: "sun.max.fill", size: 13)
            }
        }
        .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                .inset(by: MenuBarHoverStyle.inset)
                .fill(control.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous))
        .onHover { isHovered = $0 }
        .onAppear {
            localValue = control.sliderValue ?? 0
        }
        .onChange(of: control.sliderValue) { _, newValue in
            guard !isEditing else {
                return
            }

            localValue = newValue ?? localValue
        }
    }

    private func brightnessGlyph(systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size + 6, alignment: .center)
            .accessibilityHidden(true)
    }

    private func snappedSliderValue(for value: Double) -> Double {
        let bounds = control.sliderBounds ?? 0...1
        let clampedValue = min(max(value, bounds.lowerBound), bounds.upperBound)

        guard
            let step = control.sliderStep,
            step > 0
        else {
            return clampedValue
        }

        let snappedValue = (clampedValue / step).rounded() * step
        return min(max(snappedValue, bounds.lowerBound), bounds.upperBound)
    }
}

private struct SecondarySlidingPanel: View {
    private static let cornerRadius: CGFloat = 14

    let title: String
    let controls: [PluginPanelControl]
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onDateChange: (String, Date) -> Void
    let onHoverChange: (Bool) -> Void
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void

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
                onNavigationHoverChange: { _, _, _ in },
                onNavigationRowFrameChange: { _, _, _ in },
                onDateChange: onDateChange,
                onSliderChange: onSliderChange,
                onActionInvoke: { _, _ in }
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PopoverMaterialBackground()
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            )
        )
        .onHover(perform: onHoverChange)
    }
}

private final class SecondaryPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PopoverMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
    }
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

    private weak var hostWindow: NSWindow?
    private var panelWindow: SecondaryPanelWindow?
    private var panelHostingView: NSHostingView<AnyView>?
    private var hostWindowObservers: [NSObjectProtocol] = []
    var onHostWindowDismissRequest: (() -> Void)?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else {
            return
        }

        removeHostWindowObservers()
        hostWindow = window

        guard window != nil else {
            hide()
            return
        }

        observeHostWindowIfNeeded()
    }

    func show(
        panel: PluginPanelSecondaryPanel,
        anchorRect: CGRect,
        onSelectionChange: @escaping (String, String) -> Void,
        onNavigationSelectionChange: @escaping (String, String) -> Void,
        onDateChange: @escaping (String, Date) -> Void,
        onHoverChange: @escaping (Bool) -> Void,
        onSliderChange: @escaping (String, Double, PluginPanelAction.SliderPhase) -> Void
    ) {
        guard let hostWindow else { return }
        // MenuWindowAccessor.updateNSView 会在 .onDisappear 之后仍派发 async 回调，
        // 可能在 hide() 之后再次触发 show()。popover 被 dismiss 时 hostWindow 的
        // isVisible 已经变为 false，以此拦截竞态导致的侧栏重新展示。
        guard hostWindow.isVisible else { return }

        let rootView = AnyView(
            SecondarySlidingPanel(
                title: panel.title,
                controls: panel.controls,
                onSelectionChange: onSelectionChange,
                onNavigationSelectionChange: onNavigationSelectionChange,
                onDateChange: onDateChange,
                onHoverChange: onHoverChange,
                onSliderChange: onSliderChange
            )
            .frame(width: MenuBarPanelLayout.secondaryPanelWidth)
        )

        let panelWindow = panelWindow ?? makePanel()
        // 复用同一个 NSHostingView —— 如果每次 show() 都重建 contentView，
        // 鼠标按下到释放之间命中的 SwiftUI Button 会被整棵销毁，导致点击丢失
        // （现象：侧栏里点分辨率毫无反应）。保留原视图并就地更新 rootView，
        // 既保住按钮的 pressed 状态，也保留 hover 追踪。
        let hostingView: NSHostingView<AnyView>
        if let existing = panelHostingView, panelWindow.contentView === existing {
            existing.rootView = rootView
            hostingView = existing
        } else {
            let newHosting = NSHostingView(rootView: rootView)
            panelWindow.contentView = newHosting
            panelHostingView = newHosting
            hostingView = newHosting
        }

        let fittingSize = hostingView.fittingSize
        let width = MenuBarPanelLayout.secondaryPanelWidth
        let height = max(fittingSize.height, 160)
        let origin = CGPoint(
            x: anchorRect.maxX + MenuBarPanelLayout.panelSpacing,
            y: anchorRect.maxY - height
        )
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))

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
        self.panelHostingView = nil
    }

    private func makePanel() -> SecondaryPanelWindow {
        let panel = SecondaryPanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 必须保持为 false：对 LSUIElement 菜单栏应用来说，MenuBarExtra 展开时
        // 应用常处于非激活态，但菜单本身仍可交互。若开启 hidesOnDeactivate，
        // 侧栏会在展示后立即隐藏，甚至陷入 isVisible 仍为 true 但实际像素不上屏
        // 的半死状态。侧栏生命周期统一由 MenuBarContent 的 onDisappear /
        // syncSecondaryPanelWindow 来驱动 hide()。
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func observeHostWindowIfNeeded() {
        guard let hostWindow else {
            return
        }

        let notificationCenter = NotificationCenter.default
        hostWindowObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: hostWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                    self?.onHostWindowDismissRequest?()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: hostWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                    self?.onHostWindowDismissRequest?()
                }
            }
        ]
    }

    private func removeHostWindowObservers() {
        let notificationCenter = NotificationCenter.default
        hostWindowObservers.forEach(notificationCenter.removeObserver)
        hostWindowObservers.removeAll()
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

    // 每次重渲染都把窗口回传给上层 ——上层会调用 syncSecondaryPanelWindow()，
    // 充当侧栏的兜底刷新（屏幕分辨率切换、popover 短暂不可见等场景下，仅靠 onChange
    // 钩子可能错过一次需要重新 show() 的时机）。
    // 必须配合 SecondaryPanelController.show() 中的 NSHostingView 复用，否则会
    // 在 mouseDown→mouseUp 之间反复重建 contentView，导致按钮点击丢失。
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

private struct NavigationRowFrameReader: NSViewRepresentable {
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
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

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
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous)
                .inset(by: MenuBarHoverStyle.inset)
                .fill(isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous))
        .onHover { isHovered = $0 }
    }
}
