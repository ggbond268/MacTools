import AppKit
import SwiftUI
import MacToolsPluginKit

struct MenuBarHiddenSettingsView: View {
    @ObservedObject var controller: MenuBarHiddenController
    private var localization: PluginLocalization { controller.localization }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if !controller.isHostSupported {
                unsupportedSection
            }
            behaviorSection
                .disabled(!controller.isHostSupported)
                .opacity(controller.isHostSupported ? 1 : 0.4)
            layoutSection
                .disabled(!controller.isHostSupported)
                .opacity(controller.isHostSupported ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { controller.setSettingsVisible(true) }
        .onDisappear { controller.setSettingsVisible(false) }
    }

    // MARK: - Unsupported host

    private var unsupportedSection: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string(
                    "compat.unsupported.message",
                    defaultValue: "当前 macOS 版本暂不兼容菜单栏隐藏"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)
                Text(localization.string(
                    "compat.unsupported.detail",
                    defaultValue: "系统菜单栏架构变化导致图标枚举不可用，相关功能已停用"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsCardBackground(.host)
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                title: localization.string("settings.behavior.title", defaultValue: "行为"),
                icon: "switch.2"
            )

            VStack(spacing: 0) {
                toggleRow(
                    title: localization.string("settings.hideIcons.title", defaultValue: "隐藏菜单栏图标"),
                    description: localization.string(
                        "settings.hideIcons.description",
                        defaultValue: "开启后状态栏图标右侧的扩展条会隐藏其左侧的所有图标"
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
                        defaultValue: "开启后左键菜单面板显示隐藏图标卡片"
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
                        defaultValue: "开启后可将图标放入永久隐藏栏，隐藏开关关闭时也不会显示"
                    ),
                    isOn: Binding(
                        get: { controller.isAlwaysHiddenEnabled },
                        set: { controller.isAlwaysHiddenEnabled = $0 }
                    ),
                    isEnabled: controller.permissions.canManageItems
                )
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    // MARK: - Layout strip

    private var layoutSection: some View {
        let authorized = controller.permissions.canManageItems
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: 8) {
                sectionHeader(
                    title: localization.string("settings.layout.title", defaultValue: "菜单栏布局"),
                    icon: "rectangle.split.2x1"
                )
                if !authorized {
                    Label(
                        localization.string("settings.layout.authorizationRequired", defaultValue: "需要授权"),
                        systemImage: "lock.fill"
                    )
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
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
            .pluginSettingsCardBackground(.host)
            .opacity(authorized ? 1 : 0.4)
            .allowsHitTesting(authorized)
        }
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

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
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
