import SwiftUI
import MacToolsPluginKit

struct WindowSwitcherBehaviorSettingsView: View {
    enum Group { case behavior, order }
    let localization: PluginLocalization
    let group: Group
    @Binding var mode: WindowSwitcherMode
    @Binding var sortMode: WindowSwitcherSortMode

    private func text(_ key: String, _ fallback: String) -> String {
        localization.string(key, defaultValue: fallback)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch group {
            case .behavior:
                option("settings.mode.search", "搜索选择", "settings.mode.search.description", "输入搜索，按回车切换。",
                       selected: mode == .searchSelect) { mode = .searchSelect }
                Divider()
                option("settings.mode.directCycle", "连续切换", "settings.mode.directCycle.description", "按住修饰键连续选择，松开后切换。",
                       selected: mode == .directCycle) { mode = .directCycle }
                Divider()
                option("settings.mode.legacy", "按键直达", "settings.mode.legacy.description", "按窗口对应的按键立即切换。",
                       selected: mode == .keyWindow) { mode = .keyWindow }
            case .order:
                option("settings.sort.recentUse", "最近使用", "settings.sort.recentUse.description", "最近使用的窗口排在前面。",
                       selected: sortMode == .recentUse) { sortMode = .recentUse }
                Divider()
                option("settings.sort.fixed", "按名称排序", "settings.sort.fixed.description", "先按应用名称，再按窗口标题排序。",
                       selected: sortMode == .fixed) { sortMode = .fixed }
            }
        }
        .controlSize(.small)
    }

    private func option(_ key: String, _ fallback: String, _ descriptionKey: String, _ description: String,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(text(key, fallback))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(.primary)
                    Text(text(descriptionKey, description))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text(key, fallback))
        .accessibilityHint(text(descriptionKey, description))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
