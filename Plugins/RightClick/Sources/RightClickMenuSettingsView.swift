import AppKit
import SwiftUI
import MacToolsPluginKit

/// Settings view for the Finder right-click menu, shown via the plugin's
/// `PluginSettingsPage`. It writes the shared `RightClickConfiguration` (read by
/// the sandboxed extension through a read-only file exception), so the user
/// controls which items appear when right-clicking in Finder. Changes take effect
/// on the next right-click — the extension reads the config on every menu build.
@MainActor
final class RightClickSettingsSession: ObservableObject {
    @Published var configuration: RightClickConfiguration {
        didSet {
            var value = configuration
            let current = RightClickConfigurationStore.load()
            value.menuEnabled = current.menuEnabled
            value.preferredLanguages = current.preferredLanguages
            RightClickConfigurationStore.save(value)
        }
    }

    init(configuration: RightClickConfiguration = RightClickConfigurationStore.load()) {
        self.configuration = configuration
    }
}

struct RightClickMenuSettingsView: View {
    enum SectionKind {
        case directory
        case copy
        case openWith
    }

    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    let section: SectionKind

    @ViewBuilder
    var body: some View {
        switch section {
        case .directory:
            directorySection
        case .copy:
            copySection
        case .openWith:
            openWithSection
        }
    }

    private var directorySection: some View {
        VStack(spacing: 0) {
            toggleRow(title: localization.string("settings.newFolder.title", defaultValue: "新建文件夹"), isOn: $session.configuration.newFolder)
            PluginSettingsListDivider()
            toggleRow(
                title: localization.string("settings.newFile.title", defaultValue: "新建文件"),
                description: localization.string(
                    "settings.newFile.description",
                    defaultValue: "支持 .txt、.md、.json、.html 等常见扩展名"
                ),
                isOn: $session.configuration.newFile
            )
            PluginSettingsListDivider()
            toggleRow(title: localization.string("settings.openTerminal.title", defaultValue: "在终端打开"), isOn: $session.configuration.openInTerminal)
        }
    }

    private var copySection: some View {
        VStack(spacing: 0) {
            toggleRow(title: localization.string("settings.copyFileName.title", defaultValue: "复制文件名"), isOn: $session.configuration.copyFileName)
            PluginSettingsListDivider()
            toggleRow(title: localization.string("settings.copyAbsolutePath.title", defaultValue: "复制绝对路径"), isOn: $session.configuration.copyAbsolutePath)
            PluginSettingsListDivider()
            toggleRow(title: localization.string("settings.copyRelativePath.title", defaultValue: "复制相对路径"), isOn: $session.configuration.copyRelativePath)
            PluginSettingsListDivider()
            toggleRow(
                title: localization.string("settings.copyShellEscapedPath.title", defaultValue: "复制转义路径"),
                description: localization.string("settings.copyShellEscapedPath.description", defaultValue: "适合终端命令"),
                isOn: $session.configuration.copyShellEscapedPath
            )
            PluginSettingsListDivider()
            toggleRow(title: localization.string("settings.copyFileURL.title", defaultValue: "复制 file:// 链接"), isOn: $session.configuration.copyFileURL)
        }
    }

    private var openWithSection: some View {
        VStack(spacing: 0) {
            if session.configuration.openWithApps.isEmpty {
                emptyOpenWithView
            } else {
                ForEach($session.configuration.openWithApps) { $app in
                    RightClickOpenWithAppRow(app: $app) {
                        session.configuration.openWithApps.removeAll { $0.id == app.id }
                    }
                    .environment(\.rightClickLocalization, localization)
                    if app.id != session.configuration.openWithApps.last?.id {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
    }

    private var emptyOpenWithView: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "app.dashed")
                .pluginSettingsRowIconStyle()
            Text(localization.string("settings.openWith.empty", defaultValue: "暂无应用"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .pluginSettingsListRowPadding()
    }

    private func toggleRow(
        title: String,
        description: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                if let description {
                    Text(description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    /// Let the user pick a `.app` bundle and append it to the list.
    static func addApp(
        to session: RightClickSettingsSession,
        localization: PluginLocalization
    ) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = localization.string("settings.openPanel.prompt", defaultValue: "选择")
        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // displayName is localized and usually extension-free; strip only a
        // trailing ".app" rather than a global replace.
        let displayName = FileManager.default.displayName(atPath: url.path)
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        session.configuration.openWithApps.append(
            RightClickOpenWithApp(name: name, appPath: url.path, fileExtensions: [])
        )
    }
}

/// One row in the "open with" list: app name + path, an editable comma-separated
/// extension filter, and a delete button.
private struct RightClickOpenWithAppRow: View {
    @Binding var app: RightClickOpenWithApp
    let onDelete: () -> Void
    @Environment(\.rightClickLocalization) private var localization

    @State private var extensionsText: String

    init(app: Binding<RightClickOpenWithApp>, onDelete: @escaping () -> Void) {
        _app = app
        self.onDelete = onDelete
        _extensionsText = State(
            initialValue: app.wrappedValue.fileExtensions.joined(separator: ", ")
        )
    }

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(app.name)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(app.appPath)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Text(extensionsLabel)
                    .font(PluginSettingsTheme.Typography.controlLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                TextField("", text: $extensionsText)
                    .labelsHidden()
                    .accessibilityLabel(extensionsLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onChange(of: extensionsText) { _, newValue in
                        // pathExtension values are dotless; strip a leading "." so a
                        // user entering ".txt" still matches.
                        app.fileExtensions = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                            .filter { !$0.isEmpty }
                    }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(
                            width: PluginSettingsTheme.Size.controlHeight,
                            height: PluginSettingsTheme.Size.controlHeight
                        )
                }
                .buttonStyle(.plain)
                .help(localization.string("settings.deleteApp.help", defaultValue: "删除应用"))
            }
            .layoutPriority(1)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var extensionsLabel: String {
        localization.string("settings.extensions.placeholder", defaultValue: "扩展名")
    }
}

private struct RightClickLocalizationEnvironmentKey: EnvironmentKey {
    static let defaultValue = PluginLocalization(bundle: .main)
}

private extension EnvironmentValues {
    var rightClickLocalization: PluginLocalization {
        get { self[RightClickLocalizationEnvironmentKey.self] }
        set { self[RightClickLocalizationEnvironmentKey.self] = newValue }
    }
}
