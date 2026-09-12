import SwiftUI
import MacToolsPluginKit

struct CommandPaletteAliasSettingsRow: View {
    @ObservedObject var pluginHost: PluginHost
    let item: ActionInputItem
    @State private var draft = ""
    @State private var error: String?

    private var current: String { pluginHost.actionInputAliases.aliases(for: item).first ?? "" }
    private func label(_ key: String, _ fallback: String) -> String {
        AppL10n.settings("actionInput.alias." + key, defaultValue: fallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(item.definition.title).font(PluginSettingsTheme.Typography.rowTitle)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    triggerField
                    buttons
                }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    triggerField
                    buttons
                }
            }
            Text(AppL10n.settingsFormat("actionInput.alias.preview", defaultValue: "示例：%@ 你的消息 ↵", draft))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let error {
                Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = current }
        .onChange(of: current) { _, value in draft = value }
        .onChange(of: draft) { error = nil }
    }

    private var triggerField: some View {
        TextField(label("title", "触发短语"), text: $draft)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160, idealWidth: 240, maxWidth: 320)
            .accessibilityIdentifier("mactools.action-input.alias")
            .onSubmit { save(draft) }
    }

    private var buttons: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Button(label("save", "保存")) { save(draft) }
                .disabled(draft == current)
                .accessibilityIdentifier("mactools.action-input.alias.save")
            Button(label("reset", "恢复默认")) { save(nil) }
                .disabled(pluginHost.actionInputAliases.overrides[item.id.id] == nil && draft == current)
        }
        .fixedSize()
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func save(_ value: String?) {
        do {
            try pluginHost.setActionInputAlias(value, for: item)
            draft = current
            error = nil
        } catch let failure as CommandPaletteAliasStore.Failure {
            switch failure {
            case .invalid:
                error = label("invalid", "请输入不含首尾空格或换行的短语，最多 64 个字符。")
            case .unavailable:
                error = label("unavailable", "操作已更改，请重新打开设置。")
            case let .conflict(title):
                error = AppL10n.settingsFormat("actionInput.alias.conflict", defaultValue: "与“%@”的触发短语冲突。", title)
            }
        } catch { self.error = label("unavailable", "操作已更改，请重新打开设置。") }
    }
}
