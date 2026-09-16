import Combine
import MacToolsPluginKit
import SwiftUI

public final class DuoStatusPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DuoStatusPluginProvider(context: context)
    }
}

@MainActor
private struct DuoStatusPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DuoStatusPlugin(context: context)]
    }
}

@MainActor
final class DuoStatusPlugin: MacToolsPlugin, PluginSettingsPresenting,
    PluginApplicationActivityStateHandling {
    static let pluginID = "duo-status"

    private enum SettingsID {
        static let menuBar = "menu-bar"
        static let showsMenuBar = "shows-menu-bar"
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    private let storage: any PluginStorage
    private let localization: PluginLocalization
    private let monitor: any DuoSystemStatusMonitoring
    private let menuBar: any DuoStatusMenuBarPresenting
    private var localizationSubscription: AnyCancellable?
    private var isActive = false
    private var activityState: PluginApplicationActivityState = .interactive
    private(set) var showsMenuBar: Bool

    init(
        context: PluginRuntimeContext,
        monitor: (any DuoSystemStatusMonitoring)? = nil,
        menuBar: (any DuoStatusMenuBarPresenting)? = nil
    ) {
        storage = context.storage
        localization = PluginLocalization(bundle: context.resourceBundle)
        self.monitor = monitor ?? DuoSystemStatusMonitor()
        self.menuBar = menuBar ?? DuoStatusMenuBarController()
        showsMenuBar = context.storage.object(forKey: SettingsID.showsMenuBar) as? Bool ?? true

        self.monitor.onChange = { [weak self] snapshot in
            guard let self, self.isActive, self.showsMenuBar,
                  self.activityState.allowsBackgroundWork else { return }
            self.updateMenuBar(snapshot: snapshot)
        }
        self.menuBar.openSettings = { [weak self] in
            guard let self, self.isActive, self.showsMenuBar else { return }
            self.requestSettingsPresentation?()
        }
    }

    isolated deinit {
        monitor.onChange = nil
        monitor.stop()
        menuBar.openSettings = nil
        menuBar.remove()
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "Duo 状态"),
            iconName: "wifi.circle",
            iconTint: .green,
            order: 24,
            defaultDescription: localization.string(
                "metadata.description", defaultValue: "独立菜单栏图标，一眼查看电量与网络状态"
            )
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(sections: [
            PluginSettingsSection(
                id: SettingsID.menuBar,
                title: localization.string("settings.menuBar", defaultValue: "菜单栏"),
                systemImage: "menubar.rectangle",
                footer: localization.string(
                    "settings.footer",
                    defaultValue: "圆弧显示电量，圆点显示 Wi-Fi 信号。网络状态表示本机连接情况，不检测互联网是否可用。"
                ),
                rows: [
                    PluginSettingsRow(
                        id: SettingsID.showsMenuBar,
                        title: localization.string("settings.show", defaultValue: "显示 Duo 图标"),
                        description: localization.string(
                            "settings.showDescription",
                            defaultValue: "悬停查看状态，点击打开设置。关闭后停止监控。"
                        ),
                        control: .toggle(isOn: showsMenuBar)
                    )
                ]
            )
        ])
    }

    func activate(context: PluginRuntimeContext) {
        guard !isActive else { return }
        isActive = true
        localizationSubscription = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                // Locale-source publication happens before its revision changes.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updateMenuBar(snapshot: self.monitor.snapshot)
                }
            }
        applyConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActive = false
        localizationSubscription = nil
        monitor.stop()
        menuBar.remove()
    }

    func refresh() {
        applyConfiguration()
        monitor.refresh()
        onStateChange?()
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        activityState = state
        applyConfiguration()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setBoolean(id, value) = action,
              id == SettingsID.showsMenuBar, showsMenuBar != value else { return }
        showsMenuBar = value
        storage.set(value, forKey: SettingsID.showsMenuBar)
        applyConfiguration()
        onStateChange?()
    }

    private func applyConfiguration() {
        guard isActive, showsMenuBar else {
            monitor.stop()
            menuBar.remove()
            return
        }
        if activityState.allowsBackgroundWork {
            monitor.start()
        } else {
            monitor.stop()
        }
        updateMenuBar(snapshot: monitor.snapshot)
    }

    private func updateMenuBar(snapshot: DuoSystemStatusSnapshot) {
        guard isActive, showsMenuBar else { return }
        let status = DuoSystemStatusDescription(localization: localization).text(for: snapshot)
        menuBar.update(snapshot: snapshot, tooltip: "\(metadata.title)\n\(status)")
    }
}
