import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.mactools"

    static let accessibilityPermissionObserver = Logger(subsystem: subsystem, category: "AccessibilityPermissionObserver")
    static let displayConfigurationObserver = Logger(subsystem: subsystem, category: "DisplayConfigurationObserver")
    static let autoHideDockPlugin = Logger(subsystem: subsystem, category: "AutoHideDockPlugin")
    static let pluginHost = Logger(subsystem: subsystem, category: "PluginHost")
    static let launchAtLogin = Logger(subsystem: subsystem, category: "LaunchAtLogin")
    static let finderContextMenu = Logger(subsystem: subsystem, category: "FinderContextMenu")

    static var isVerboseLoggingEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACTOOLS_VERBOSE_LOGS"] == "1"
        #else
        false
        #endif
    }
}
