import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

/// Classifies AppleScript / Apple Event failures that stem from the user denying
/// the Automation privacy permission, and turns them into actionable guidance.
enum AutomationDenial {
    /// `errAEEventNotPermitted` — the app is not allowed to send Apple events to the target.
    static let notPermittedErrorNumber = -1743
    /// `errAEEventWouldRequireUserConsent` — consent has not been granted yet.
    static let consentRequiredErrorNumber = -1744

    static func isDenied(errorNumber: Int?) -> Bool {
        errorNumber == notPermittedErrorNumber || errorNumber == consentRequiredErrorNumber
    }

    static func isDenied(_ error: Error) -> Bool {
        isDenied(errorNumber: (error as NSError).code)
    }

    /// Returns actionable guidance when `error` is an Automation-denied failure, otherwise `nil`.
    static func message(for error: Error, targetAppName: String) -> String? {
        guard isDenied(error) else { return nil }
        return message(targetAppName: targetAppName)
    }

    static func message(targetAppName: String) -> String {
        "需要自动化权限：请在 系统设置 › 隐私与安全性 › 自动化 中允许 MacTools 控制“\(targetAppName)”后重试。"
    }
}

protocol DockCommandRunning {
    func setDockAutohide(_ isEnabled: Bool) throws
}

struct ProcessDockCommandRunner: DockCommandRunning {
    func setDockAutohide(_ isEnabled: Bool) throws {
        let script = """
        tell application "System Events"
            tell dock preferences
                set autohide to \(isEnabled ? "true" : "false")
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AutoHideDockPlugin",
                code: (error[NSAppleScript.errorNumber] as? Int) ?? 1,
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "切换 Dock 自动隐藏失败"]
            )
        }
    }
}

public final class AutoHideDockPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoHideDockPluginProvider()
    }
}

@MainActor
private struct AutoHideDockPluginProvider: PluginProvider {
    func makePlugins() -> [any MacToolsPlugin] {
        [AutoHideDockPlugin()]
    }
}

@MainActor
final class AutoHideDockPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "auto-hide-dock",
        title: "自动隐藏程序坞",
        iconName: "rectangle.bottomthird.inset.filled",
        iconTint: Color(nsColor: .systemBlue),
        order: 45,
        defaultDescription: "自动隐藏程序坞，提供更干净的桌面环境"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AutoHideDockPlugin")
    private let commandRunner: any DockCommandRunning
    private let stateReader: () -> Bool

    private var isDockHidden: Bool
    private var lastErrorMessage: String?

    init(
        commandRunner: any DockCommandRunning = ProcessDockCommandRunner(),
        stateReader: @escaping () -> Bool = { AutoHideDockPlugin.readDockAutohideState() }
    ) {
        self.commandRunner = commandRunner
        self.stateReader = stateReader
        self.isDockHidden = stateReader()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isDockHidden ? "已开启" : "已关闭",
            isOn: isDockHidden,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        let latestState = stateReader()
        if latestState != isDockHidden {
            isDockHidden = latestState
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        setDockHidden(isEnabled)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private func setDockHidden(_ isEnabled: Bool) {
        do {
            try commandRunner.setDockAutohide(isEnabled)
            isDockHidden = isEnabled
            lastErrorMessage = nil
            onStateChange?()
        } catch {
            logger.error("Failed to update Dock auto-hide: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = AutomationDenial.message(for: error, targetAppName: "系统事件")
                ?? error.localizedDescription
            refresh()
            onStateChange?()
        }
    }

    private nonisolated static func readDockAutohideState() -> Bool {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        return defaults?.object(forKey: "autohide") as? Bool ?? false
    }
}
