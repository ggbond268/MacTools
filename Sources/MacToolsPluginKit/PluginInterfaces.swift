import SwiftUI

@MainActor
public protocol MacToolsPlugin: AnyObject {
    var metadata: PluginMetadata { get }
    var primaryPanel: (any PluginPrimaryPanel)? { get }
    var componentPanel: (any PluginComponentPanel)? { get }
    var permissionRequirements: [PluginPermissionRequirement] { get }
    var settingsSections: [PluginSettingsSection] { get }
    var shortcutDefinitions: [PluginShortcutDefinition] { get }
    var configuration: PluginConfiguration? { get }
    var onStateChange: (() -> Void)? { get set }
    var requestPermissionGuidance: ((String) -> Void)? { get set }
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)? { get set }

    func refresh()
    func activate(context: PluginRuntimeContext)
    func deactivate(reason: PluginDeactivationReason)
    func permissionState(for permissionID: String) -> PluginPermissionState
    func handlePermissionAction(id: String)
    func handleSettingsAction(id: String)
    func handleShortcutAction(id: String)
}

@MainActor
public protocol PluginPrimaryPanel: AnyObject {
    var primaryPanelDescriptor: PluginPrimaryPanelDescriptor { get }
    var primaryPanelState: PluginPanelState { get }

    func handleAction(_ action: PluginPanelAction)
}

public extension MacToolsPlugin {
    var primaryPanel: (any PluginPrimaryPanel)? {
        nil
    }

    var componentPanel: (any PluginComponentPanel)? {
        nil
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        []
    }

    var settingsSections: [PluginSettingsSection] {
        []
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        []
    }

    var configuration: PluginConfiguration? {
        nil
    }

    func refresh() {}

    func activate(context: PluginRuntimeContext) {}

    func deactivate(reason: PluginDeactivationReason) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}

public extension MacToolsPlugin where Self: PluginPrimaryPanel {
    var primaryPanel: (any PluginPrimaryPanel)? {
        self
    }
}

@MainActor
public protocol PluginComponentPanel: AnyObject {
    var descriptor: PluginComponentDescriptor { get }
    var componentPanelState: PluginComponentState { get }

    func makeView(context: PluginComponentContext) -> AnyView
}

public extension MacToolsPlugin where Self: PluginComponentPanel {
    var componentPanel: (any PluginComponentPanel)? {
        self
    }
}

@MainActor
public protocol PluginProvider {
    func makePlugins() -> [any MacToolsPlugin]
}

public protocol MacToolsPluginBundleFactory: AnyObject {
    static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider
}

@MainActor
public protocol PluginConfigurationPresenting: AnyObject {
    var requestPluginConfigurationPresentation: ((String) -> Void)? { get set }
}

@MainActor
public protocol AccessibilityPermissionRefreshing {
    func refreshAccessibilityPermission()
}

@MainActor
public protocol DisplayTopologyRefreshing {
    func refreshDisplayTopology()
}

/// 可选协议——仅需要浮动窗口锚点的插件才声明遵从。
/// 不修改 `MacToolsPlugin` witness table，对已安装旧插件无影响。
@MainActor
public protocol DropZoneAnchorProviding: AnyObject {
    /// 宿主注入：返回状态栏图标按钮在屏幕坐标系中的 frame。
    var anchorRectProvider: (() -> NSRect?)? { get set }
}

/// 可选协议——需要保护宿主菜单栏状态项位置的插件才声明遵从。
@MainActor
public protocol MenuBarHostStatusItemRecovering: AnyObject {
    var hostStatusItemFrameProvider: (() -> NSRect?)? { get set }
    var resetHostStatusItemPosition: (() -> Void)? { get set }
}
