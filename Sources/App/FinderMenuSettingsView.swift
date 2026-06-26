import SwiftUI

/// Host-app settings page for the Finder context menu. It writes the shared
/// `FinderMenuConfiguration` (read by the sandboxed extension through the app
/// group), so the user controls which items appear when right-clicking in
/// Finder. Changes take effect on the next right-click — the extension reads the
/// config on every `menu(for:)`.
struct FinderMenuSettingsView: View {
    @State private var configuration = FinderMenuConfigStore.load()

    var body: some View {
        Form {
            Section {
                Toggle("复制绝对路径", isOn: $configuration.copyAbsolutePath)
                Toggle("复制转义路径（终端）", isOn: $configuration.copyShellEscapedPath)
                Toggle("复制文件名", isOn: $configuration.copyFileName)
                Toggle("复制 file:// 链接", isOn: $configuration.copyFileURL)
            } header: {
                Text("「复制路径」子菜单")
            } footer: {
                Text("控制在 Finder 中右键时,「复制路径」子菜单里显示哪些项。")
            }

            Section("其他菜单项") {
                Toggle("新建文件（.txt / .md / .json）", isOn: $configuration.newFileEnabled)
                Toggle("在终端打开", isOn: $configuration.openInTerminal)
            }
        }
        .formStyle(.grouped)
        .onChange(of: configuration) { _, newValue in
            FinderMenuConfigStore.save(newValue)
        }
    }
}
