import SwiftUI
import MacToolsPluginKit

@MainActor
final class PluginUninstallConfirmationSession: ObservableObject {
    @Published private(set) var isConfirmationPaused = false

    var shouldConfirmUninstall: Bool {
        !isConfirmationPaused
    }

    func shouldConfirmUninstall(removesData: Bool) -> Bool {
        removesData || shouldConfirmUninstall
    }

    func pauseConfirmation() {
        isConfirmationPaused = true
    }

    func resumeConfirmation() {
        isConfirmationPaused = false
    }
}

struct PluginUninstallConfirmation: Identifiable, Equatable {
    let pluginID: String
    let pluginTitle: String
    let surfaceCapabilitySummary: String
    let removesDataOnUninstall: Bool

    var id: String {
        pluginID
    }
}

struct PluginUninstallConfirmationSheet: View {
    let confirmation: PluginUninstallConfirmation
    @ObservedObject var session: PluginUninstallConfirmationSession
    let onConfirm: (PluginUninstallConfirmation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pausesConfirmationForSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(AppL10n.pluginsFormat(
                    "plugin.management.uninstall.confirmationTitle",
                    defaultValue: "卸载“%@”？",
                    confirmation.pluginTitle
                ))
                .font(PluginSettingsTheme.Typography.pageTitle)

                Text(confirmation.removesDataOnUninstall
                    ? AppL10n.pluginsFormat(
                        "plugin.management.uninstall.confirmationMessageRemovesData",
                        defaultValue: "它将从%@移除，快捷键、设置入口和插件私密数据也会永久删除，后台工作将停止。此操作无法撤销。",
                        confirmation.surfaceCapabilitySummary
                    )
                    : AppL10n.pluginsFormat(
                        "plugin.management.uninstall.confirmationMessage",
                        defaultValue: "它将从%@移除，快捷键和设置入口也会移除，后台工作将停止。插件数据会保留。",
                        confirmation.surfaceCapabilitySummary
                    ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !confirmation.removesDataOnUninstall {
                Toggle(
                    AppL10n.plugins(
                        "plugin.management.uninstall.pauseConfirmation",
                        defaultValue: "在本次设置会话中不再询问"
                    ),
                    isOn: $pausesConfirmationForSession
                )
                .toggleStyle(.checkbox)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Spacer()

                Button(AppL10n.settings("common.cancel", defaultValue: "取消")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(
                    AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"),
                    role: .destructive
                ) {
                    if pausesConfirmationForSession {
                        session.pauseConfirmation()
                    }
                    dismiss()
                    onConfirm(confirmation)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(width: 440, alignment: .leading)
    }
}

struct PluginUninstallConfirmationPausedBanner: View {
    @ObservedObject var session: PluginUninstallConfirmationSession

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Label(
                AppL10n.plugins(
                    "plugin.management.uninstall.confirmationPausedNotice",
                    defaultValue: "本次设置会话已暂停卸载确认。"
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(AppL10n.plugins(
                "plugin.management.uninstall.resumeConfirmation",
                defaultValue: "重新开启确认"
            )) {
                session.resumeConfirmation()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card, style: .continuous))
    }
}
