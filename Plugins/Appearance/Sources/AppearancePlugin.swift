import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class AppearancePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppearancePluginProvider(context: context)
    }
}

@MainActor
private struct AppearancePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AppearancePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AppearancePlugin: MacToolsPlugin, PluginPrimaryPanel, PluginActionProviding,
    PluginActionPermissionProviding
{
    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let toggle = "toggle"
    }
    private enum PermissionID {
        static let automation = "automation"
    }
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AppearancePlugin")
    private let localization: PluginLocalization
    private var isDarkMode: Bool = false
    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "appearance",
            title: localization.string("metadata.title", defaultValue: "深色模式"),
            iconName: "circle.lefthalf.filled",
            iconTint: Color(nsColor: .systemIndigo),
            order: 30,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "切换系统亮色与深色外观"
            )
        )
        isDarkMode = Self.readSystemDarkMode()
        observeSystemAppearanceChanges()
    }

    deinit {
        if let observer = themeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isDarkMode
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isDarkMode,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "自动化"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "切换系统外观时需要控制系统事件。"
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "深色模式"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "切换系统亮色与深色外观"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "深色模式"),
                    localization.string("metadata.description", defaultValue: "切换系统亮色与深色外观"),
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "深色模式"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "切换系统亮色与深色外观"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "深色模式"),
                    localization.string("metadata.description", defaultValue: "切换系统亮色与深色外观"),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("metadata.title", defaultValue: "深色模式"),
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: isDarkMode
                    ? localization.string("action.enableLight.title", defaultValue: "启用浅色模式")
                    : localization.string("action.enableDark.title", defaultValue: "启用深色模式"),
                subtitle: isDarkMode
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
                presentationState: isDarkMode ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.enableDark.title", defaultValue: "启用深色模式")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.enableLight.title", defaultValue: "启用浅色模式")
            ),
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(
            isGranted: false,
            footnote: permissionID == PermissionID.automation
                ? localization.string(
                    "permission.automation.footnote",
                    defaultValue: "macOS 会在首次使用时请求自动化授权。"
                )
                : nil,
            statusText: permissionID == PermissionID.automation
                ? localization.string("permission.automation.status", defaultValue: "按需确认")
                : nil,
            statusSystemImage: permissionID == PermissionID.automation ? "cursorarrow.click.2" : nil,
            statusTone: permissionID == PermissionID.automation ? .neutral : nil
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.automation else { return }
        requestPermissionGuidance?(PermissionID.automation)
    }
    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id else { return [] }
        return [PermissionID.automation]
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let enabled: Bool
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            enabled = !Self.readSystemDarkMode()
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setDarkMode(enabled)
        let failureMessage = localization.string(
            "error.toggleFailed",
            defaultValue: "切换系统外观失败。"
        )
        return ActionExecutionHandle {
            succeeded
                ? .succeeded()
                : .failed(message: failureMessage)
        }
    }

    func refresh() {
        let current = Self.readSystemDarkMode()
        if current != isDarkMode {
            isDarkMode = current
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        setDarkMode(enable)
    }

    // MARK: - Private

    private static func readSystemDarkMode() -> Bool {
        let style = UserDefaults(suiteName: ".GlobalPreferences")?.string(forKey: "AppleInterfaceStyle")
        return style == "Dark"
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    @discardableResult
    private func setDarkMode(_ enable: Bool) -> Bool {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enable ? "true" : "false")
            end tell
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            logger.error("Failed to set dark mode: \(error)")
            return false
        } else {
            isDarkMode = enable
            onStateChange?()
            return true
        }
    }

    private func observeSystemAppearanceChanges() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let current = Self.readSystemDarkMode()
                if current != self.isDarkMode {
                    self.isDarkMode = current
                    self.onStateChange?()
                }
            }
        }
    }
}
