import AppKit
import SwiftUI

/// Host-app settings page for the Finder context menu. It writes the shared
/// `FinderMenuConfiguration` (read by the sandboxed extension through a read-only
/// file-access exception), so the user controls which items appear when
/// right-clicking in Finder. Changes take effect on the next right-click — the
/// extension reads the config on every `menu(for:)`.
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

            Section {
                if configuration.openWithApps.isEmpty {
                    Text("暂无应用")
                        .foregroundStyle(.secondary)
                }
                ForEach($configuration.openWithApps) { $app in
                    OpenWithAppRow(app: $app) {
                        configuration.openWithApps.removeAll { $0.id == app.id }
                    }
                }
                Button {
                    addApp()
                } label: {
                    Label("添加应用…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("「用应用打开」子菜单")
            } footer: {
                Text("右键文件时用指定应用打开。扩展名留空表示对所有文件显示;多个扩展名用逗号分隔。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: configuration) { _, newValue in
            FinderMenuConfigStore.save(newValue)
        }
    }

    /// Let the user pick a `.app` bundle and append it to the list.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // displayName is already localized and usually extension-free; strip only
        // a trailing ".app" rather than a global replace (which could clip a
        // ".app" substring in the middle of a name).
        let displayName = FileManager.default.displayName(atPath: url.path)
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        configuration.openWithApps.append(
            OpenWithApp(name: name, appPath: url.path, fileExtensions: [])
        )
    }
}

/// One row in the "Open with app" list: app name + path, an editable
/// comma-separated extension filter, and a delete button.
private struct OpenWithAppRow: View {
    @Binding var app: OpenWithApp
    let onDelete: () -> Void

    /// Comma-separated extensions, edited as text and synced back to
    /// `app.fileExtensions` (lowercased, trimmed, de-blanked).
    @State private var extensionsText: String

    init(app: Binding<OpenWithApp>, onDelete: @escaping () -> Void) {
        _app = app
        self.onDelete = onDelete
        _extensionsText = State(
            initialValue: app.wrappedValue.fileExtensions.joined(separator: ", ")
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.appPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            TextField("扩展名", text: $extensionsText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onChange(of: extensionsText) { _, newValue in
                    app.fileExtensions = newValue
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}
