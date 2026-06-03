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

    static func message(targetAppName: String) -> String {
        "需要自动化权限：请在 系统设置 › 隐私与安全性 › 自动化 中允许 MacTools 控制“\(targetAppName)”后重试。"
    }
}

public final class AppearancePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppearancePluginProvider()
    }
}

@MainActor
private struct AppearancePluginProvider: PluginProvider {
    func makePlugins() -> [any MacToolsPlugin] {
        [AppearancePlugin()]
    }
}

@MainActor
final class AppearancePlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "appearance",
        title: "深色模式",
        iconName: "circle.lefthalf.filled",
        iconTint: Color(nsColor: .systemIndigo),
        order: 30,
        defaultDescription: "切换系统亮色与深色外观"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AppearancePlugin")
    private var isDarkMode: Bool = false
    private var lastErrorMessage: String?
    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    init() {
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
            subtitle: isDarkMode ? "已开启" : "已关闭",
            isOn: isDarkMode,
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

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

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

    private func setDarkMode(_ enable: Bool) {
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
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
            if AutomationDenial.isDenied(errorNumber: errorNumber) {
                lastErrorMessage = AutomationDenial.message(targetAppName: "系统事件")
            } else {
                let message = (error[NSAppleScript.errorMessage] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lastErrorMessage = message?.isEmpty == false ? message : "切换深色模式失败"
            }
            // Re-sync the toggle to the real system state so it doesn't appear flipped.
            isDarkMode = Self.readSystemDarkMode()
            onStateChange?()
        } else {
            isDarkMode = enable
            lastErrorMessage = nil
            onStateChange?()
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
