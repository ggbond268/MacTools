import SwiftUI

@MainActor
protocol PluginCore: AnyObject {
    var metadata: PluginMetadata { get }
    var permissionRequirements: [PluginPermissionRequirement] { get }
    var settingsSections: [PluginSettingsSection] { get }
    var shortcutDefinitions: [PluginShortcutDefinition] { get }
    var onStateChange: (() -> Void)? { get set }
    var requestPermissionGuidance: ((String) -> Void)? { get set }
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)? { get set }

    func refresh()
    func permissionState(for permissionID: String) -> PluginPermissionState
    func handlePermissionAction(id: String)
    func handleSettingsAction(id: String)
    func handleShortcutAction(id: String)
}

@MainActor
protocol FeaturePlugin: PluginCore {
    var manifest: PluginManifest { get }
    var panelState: PluginPanelState { get }

    func handlePanelAction(_ action: PluginPanelAction)
}

extension FeaturePlugin {
    var metadata: PluginMetadata {
        manifest.metadata
    }
}

@MainActor
protocol ComponentPlugin: PluginCore {
    var componentDescriptor: PluginComponentDescriptor { get }
    var componentState: PluginComponentState { get }

    func makeComponentView(context: PluginComponentContext) -> AnyView
}
