import AppKit
import SwiftUI

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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var pluginHost: PluginHost
    @State private var deferredPanelSwitchAction: DeferredPanelSwitchAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            pluginHost.setPanelSelectionValue(
                                optionID,
                                controlID: controlID,
                                for: item.id
                            )
                        },
                        onDateChange: { controlID, date in
                            pluginHost.setPanelDateValue(
                                date,
                                controlID: controlID,
                                for: item.id
                            )
                        }
                    )
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

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
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(pluginHost.$settingsPresentationRequestCount.dropFirst()) { _ in
            presentSettings()
        }
        .onDisappear {
            flushDeferredPanelSwitchActionIfNeeded()
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
}

struct FeatureRowView: View {
    let item: PluginPanelItem
    @Binding var isOn: Bool
    let onDisclosureToggle: (Bool) -> Void
    let onSelectionChange: (String, String) -> Void
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
            }

            if let detail = detailToDisplay {
                PluginPanelDetailView(
                    detail: detail,
                    onSelectionChange: onSelectionChange,
                    onDateChange: onDateChange
                )
                .padding(.leading, FeatureRowLayout.detailLeadingInset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
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
                Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
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
    let onSelectionChange: (String, String) -> Void
    let onDateChange: (String, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(detail.controls) { control in
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
