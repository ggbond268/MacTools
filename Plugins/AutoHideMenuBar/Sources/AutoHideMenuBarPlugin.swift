import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

protocol MenuBarCommandRunning {
    func setMenuBarAutohide(_ isEnabled: Bool) throws
}

struct ProcessMenuBarCommandRunner: MenuBarCommandRunning {
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func setMenuBarAutohide(_ isEnabled: Bool) throws {
        let script = """
        tell application "System Events"
            tell dock preferences
                set autohide menu bar to \(isEnabled ? "true" : "false")
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AutoHideMenuBarPlugin",
                code: (error[NSAppleScript.errorNumber] as? Int) ?? 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message!
                        : localization.string(
                            "error.toggleFailed",
                            defaultValue: "切换菜单栏自动隐藏失败"
                        )
                ]
            )
        }
    }
}

public final class AutoHideMenuBarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoHideMenuBarPluginProvider(context: context)
    }
}

@MainActor
private struct AutoHideMenuBarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AutoHideMenuBarPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AutoHideMenuBarPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginActionProviding,
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AutoHideMenuBarPlugin")
    private let commandRunner: any MenuBarCommandRunning
    private let stateReader: () -> Bool
    private let localization: PluginLocalization

    private var isMenuBarHidden: Bool
    private var lastErrorMessage: String?

    init(
        commandRunner: (any MenuBarCommandRunning)? = nil,
        stateReader: @escaping () -> Bool = { AutoHideMenuBarPlugin.readMenuBarAutohideState() },
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.commandRunner = commandRunner ?? ProcessMenuBarCommandRunner(localization: localization)
        self.stateReader = stateReader
        self.metadata = PluginMetadata(
            id: "auto-hide-menu-bar",
            title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
            iconName: "menubar.rectangle",
            iconTint: Color(nsColor: .systemIndigo),
            order: 42,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"
            )
        )
        self.isMenuBarHidden = stateReader()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isMenuBarHidden
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isMenuBarHidden,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
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
                    defaultValue: "切换菜单栏自动隐藏时需要控制系统事件。"
                )
            ),
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                description: localization.string("metadata.description", defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"),
                keywords: [
                    localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                    localization.string("metadata.description", defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"),
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
                    localization.string("metadata.description", defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"),
                ],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
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
                title: isMenuBarHidden
                    ? localization.string("action.show.title", defaultValue: "显示菜单栏")
                    : localization.string("action.hide.title", defaultValue: "隐藏菜单栏"),
                subtitle: isMenuBarHidden
                    ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                    : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
                presentationState: isMenuBarHidden ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: localization.string("action.hide.title", defaultValue: "隐藏菜单栏")
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: localization.string("action.show.title", defaultValue: "显示菜单栏")
            ),
        ]
    }

    func refresh() {
        let latestState = stateReader()
        if latestState != isMenuBarHidden {
            isMenuBarHidden = latestState
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        setMenuBarHidden(isEnabled)
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
            enabled = !stateReader()
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            enabled = value
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        let succeeded = setMenuBarHidden(enabled)
        let failureMessage = localization.string(
            "error.toggleFailed",
            defaultValue: "切换菜单栏自动隐藏失败"
        )
        return ActionExecutionHandle {
            succeeded
                ? .succeeded()
                : .failed(message: failureMessage)
        }
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
    private func setMenuBarHidden(_ isEnabled: Bool) -> Bool {
        do {
            try commandRunner.setMenuBarAutohide(isEnabled)
            isMenuBarHidden = isEnabled
            lastErrorMessage = nil
            onStateChange?()
            return true
        } catch {
            logger.error("Failed to update menu bar auto-hide: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            refresh()
            onStateChange?()
            return false
        }
    }

    nonisolated static func readMenuBarAutohideState(
        globalDefaults: UserDefaults = .standard,
        dockDefaults: UserDefaults? = UserDefaults(suiteName: "com.apple.dock")
    ) -> Bool {
        resolvedMenuBarAutohideState(
            globalValue: globalDefaults.object(forKey: "_HIHideMenuBar"),
            dockValue: dockDefaults?.object(forKey: "autohide-menubar")
        )
    }

    nonisolated static func resolvedMenuBarAutohideState(globalValue: Any?, dockValue: Any?) -> Bool {
        if let value = boolValue(from: globalValue) {
            return value
        }

        if let value = boolValue(from: dockValue) {
            return value
        }

        return false
    }

    private nonisolated static func boolValue(from value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        default:
            nil
        }
    }
}
