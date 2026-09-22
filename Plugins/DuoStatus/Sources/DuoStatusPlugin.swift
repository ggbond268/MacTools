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
    PluginApplicationActivityStateHandling, PluginMenuBarIconProviding,
    PluginMenuBarIconHostContextConsuming {
    static let pluginID = "duo-status"
    static let iconID = "status"

    private enum SettingsID {
        static let menuBar = "menu-bar"
        static let placement = "placement"
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    var onMenuBarIconChange: ((String) -> Void)?
    var menuBarIconHostContext: PluginMenuBarIconHostContext? {
        didSet { applyConfiguration() }
    }
    private let localization: PluginLocalization
    private let monitor: any DuoSystemStatusMonitoring
    private let menuBar: any DuoStatusMenuBarPresenting
    private var localizationSubscription: AnyCancellable?
    private var isActive = false
    private var activityState: PluginApplicationActivityState = .interactive
    private var placementError: PluginMenuBarIconPlacementError?
    private var iconRevision: UInt64 = 0
    private var cachedIcon: (PluginMenuBarIconRenderContext, PluginMenuBarIconSnapshot)?

    var placement: PluginMenuBarIconPlacement {
        menuBarIconHostContext?.placement(for: Self.iconID) ?? .standalone
    }

    init(
        context: PluginRuntimeContext,
        monitor: (any DuoSystemStatusMonitoring)? = nil,
        menuBar: (any DuoStatusMenuBarPresenting)? = nil
    ) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        self.monitor = monitor ?? DuoSystemStatusMonitor()
        self.menuBar = menuBar ?? DuoStatusMenuBarController()
        self.monitor.onChange = { [weak self] snapshot in
            guard let self, self.isActive, self.menuBarIconHostContext != nil,
                  self.activityState.allowsBackgroundWork else { return }
            self.iconDidChange(snapshot: snapshot)
        }
        self.menuBar.openSettings = { [weak self] in
            guard let self, self.isActive, self.menuBarIconHostContext != nil,
                  self.placement == .standalone else { return }
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
                "metadata.description", defaultValue: "通过独立图标或应用主图标查看电量与网络状态"
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
                        id: SettingsID.placement,
                        title: localization.string("settings.placement", defaultValue: "显示方式"),
                        description: placement == .primary
                            ? localization.string("settings.primaryDescription", defaultValue: "替换 MacTools 主图标，点击行为保持不变。")
                            : localization.string("settings.standaloneDescription", defaultValue: "独立显示，悬停查看状态，点击打开设置。"),
                        error: placementErrorMessage,
                        isEnabled: menuBarIconHostContext != nil,
                        control: .picker(
                            selectionID: placement.rawValue,
                            options: [
                                .init(id: PluginMenuBarIconPlacement.standalone.rawValue,
                                      title: localization.string("settings.standalone", defaultValue: "独立图标")),
                                .init(id: PluginMenuBarIconPlacement.primary.rawValue,
                                      title: localization.string("settings.primary", defaultValue: "替换应用图标"))
                            ],
                            style: .segmented
                        )
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
                    self.iconDidChange(snapshot: self.monitor.snapshot)
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
        guard case let .setSelection(id, optionID) = action,
              id == SettingsID.placement,
              let placement = PluginMenuBarIconPlacement(rawValue: optionID) else { return }
        let result = menuBarIconHostContext?.requestPlacement(placement, for: Self.iconID)
            ?? .failure(.unavailable)
        switch result {
        case .success:
            placementError = nil
            applyConfiguration()
        case let .failure(error):
            placementError = error
        }
        onStateChange?()
    }

    var menuBarIconDescriptors: [PluginMenuBarIconDescriptor] {
        [.init(id: Self.iconID, title: metadata.title)]
    }

    func menuBarIcon(
        for iconID: String,
        context: PluginMenuBarIconRenderContext
    ) -> PluginMenuBarIconSnapshot? {
        guard iconID == Self.iconID else { return nil }
        if let cachedIcon, cachedIcon.0 == context { return cachedIcon.1 }
        let image = DuoStatusIcon.image(
            for: monitor.snapshot,
            appearance: context.appearance == .dark ? .dark : .light,
            pointSize: context.pointSize
        )
        let description = "\(metadata.title)\n\(DuoSystemStatusDescription(localization: localization).text(for: monitor.snapshot))"
        let snapshot = PluginMenuBarIconSnapshot(
            revision: iconRevision,
            image: image,
            isTemplate: image.isTemplate,
            tooltip: description,
            accessibilityDescription: description
        )
        cachedIcon = (context, snapshot)
        return snapshot
    }

    func menuBarIconPlacementDidChange() {
        placementError = nil
        applyConfiguration()
        onStateChange?()
    }

    private var placementErrorMessage: String? {
        switch placementError {
        case let .occupied(owner):
            let owner = menuBarIconHostContext?.primaryIconOwner ?? owner
            if owner.requiresRestart {
                return localization.format(
                    "settings.occupiedPendingRestartFormat",
                    defaultValue: "「%@」正在等待重启。请重启 MacTools 后调整其图标设置。",
                    owner.pluginTitle
                )
            }
            return localization.format(
                "settings.occupiedFormat",
                defaultValue: "应用图标已由「%@」使用。请先在其设置中取消替换。",
                owner.pluginTitle
            )
        case .unavailable:
            return localization.string("settings.unavailable", defaultValue: "暂时无法切换显示方式，请稍后重试。")
        case .invalidIcon:
            return localization.string("settings.invalidIcon", defaultValue: "图标暂不可用，已保留当前显示方式。")
        case nil:
            return nil
        }
    }

    private func applyConfiguration() {
        // Wait for host registration so a restored primary placement never creates a duplicate item.
        guard isActive, menuBarIconHostContext != nil else {
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
        guard isActive, menuBarIconHostContext != nil else { return }
        guard placement == .standalone else {
            menuBar.remove()
            return
        }
        let status = DuoSystemStatusDescription(localization: localization).text(for: snapshot)
        menuBar.update(snapshot: snapshot, tooltip: "\(metadata.title)\n\(status)")
    }

    private func iconDidChange(snapshot: DuoSystemStatusSnapshot) {
        guard isActive else { return }
        iconRevision &+= 1
        cachedIcon = nil
        updateMenuBar(snapshot: snapshot)
        onMenuBarIconChange?(Self.iconID)
    }
}
