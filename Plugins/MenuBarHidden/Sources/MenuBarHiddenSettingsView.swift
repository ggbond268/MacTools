import AppKit
import SwiftUI
import MacToolsPluginKit

struct MenuBarHiddenSettingsView: View {
    enum SectionKind {
        case behavior
        case layout
    }

    @ObservedObject var controller: MenuBarHiddenController
    let section: SectionKind
    private var localization: PluginLocalization { controller.localization }

    @ViewBuilder
    var body: some View {
        switch section {
        case .behavior:
            behaviorSection
        case .layout:
            layoutSection
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(spacing: 0) {
            toggleRow(
                    title: localization.string("settings.hideIcons.title", defaultValue: "隐藏菜单栏图标"),
                    description: localization.string(
                        "settings.hideIcons.description",
                        defaultValue: "开启后用分割符隐藏左侧图标；点击分割符可在聚合浮窗中临时显示隐藏图标。"
                    ),
                    isOn: Binding(
                        get: { controller.isEnabled },
                        set: { controller.isEnabled = $0 }
                    )
            )
            Divider()
                    .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)
            toggleRow(
                    title: localization.string("settings.showInPanel.title", defaultValue: "面板中显示隐藏图标"),
                    description: localization.string(
                        "settings.showInPanel.description",
                        defaultValue: "在功能面板中显示隐藏图标卡片，方便不点分割符也能管理。"
                    ),
                    isOn: Binding(
                        get: { controller.showsHiddenIconsInPanel },
                        set: { controller.showsHiddenIconsInPanel = $0 }
                    ),
                    isEnabled: controller.permissions.canManageItems
            )
            Divider()
                    .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)
            toggleRow(
                    title: localization.string("settings.alwaysHidden.title", defaultValue: "永久隐藏"),
                    description: localization.string(
                        "settings.alwaysHidden.description",
                        defaultValue: "永久隐藏区中的图标在关闭「隐藏菜单栏图标」后也不会回到菜单栏，适合很少使用的图标。"
                    ),
                    isOn: Binding(
                        get: { controller.isAlwaysHiddenEnabled },
                        set: { controller.isAlwaysHiddenEnabled = $0 }
                    ),
                    isEnabled: controller.permissions.canManageItems
            )
        }
    }

    // MARK: - Layout strip

    private var layoutSection: some View {
        let authorized = controller.permissions.canManageItems
        return VStack(alignment: .leading, spacing: 12) {
            if !authorized {
                HStack {
                    Label(
                        localization.string("settings.layout.authorizationRequired", defaultValue: "需要授权"),
                        systemImage: "lock.fill"
                    )
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Spacer()
                }
            }

            stripRow(
                    title: MenuBarHiddenSection.visible.title(localization: localization),
                    section: .visible,
                    items: authorized ? controller.snapshot.visibleItems : []
                )
            stripRow(
                    title: MenuBarHiddenSection.hidden.title(localization: localization),
                    section: .hidden,
                    items: authorized ? controller.snapshot.hiddenItems : []
                )
            if controller.isAlwaysHiddenEnabled {
                stripRow(
                        title: MenuBarHiddenSection.alwaysHidden.title(localization: localization),
                        section: .alwaysHidden,
                        items: authorized ? controller.snapshot.alwaysHiddenItems : []
                )
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .opacity(authorized ? 1 : 0.4)
        .allowsHitTesting(authorized)
    }

    // MARK: - Rows

    private func stripRow(title: String, section: MenuBarHiddenSection, items: [MenuBarItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text("\(items.count)")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            Group {
                ZStack {
                    MenuBarHiddenLayoutStripRow(
                        section: section,
                        items: items,
                        iconCache: controller.manager.iconCache,
                        controller: controller
                    )

                    if items.isEmpty {
                        Text(
                            controller.permissions.canManageItems
                                ? localization.string(
                                    "settings.layout.emptyDropTarget",
                                    defaultValue: "拖入菜单栏图标到此区域"
                                )
                                : "-"
                        )
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .menuBarHiddenDefaultLayoutBar))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func toggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
                .disabled(!isEnabled)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .opacity(isEnabled ? 1 : 0.45)
    }

}

private struct MenuBarHiddenLayoutStripRow: View {
    let section: MenuBarHiddenSection
    let items: [MenuBarItem]
    let iconCache: MenuBarHiddenIconCache
    let controller: MenuBarHiddenController

    @State private var height: CGFloat = 48

    var body: some View {
        MenuBarHiddenLayoutStrip(
            section: section,
            items: items,
            iconCache: iconCache,
            controller: controller,
            measuredHeight: $height
        )
        .frame(maxWidth: .infinity, minHeight: height, idealHeight: height)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension NSColor {
    static var menuBarHiddenDefaultLayoutBar: NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor.white.withAlphaComponent(0.10)
            }
            return NSColor(srgbRed: 0.38, green: 0.39, blue: 0.35, alpha: 1)
        }
    }
}
