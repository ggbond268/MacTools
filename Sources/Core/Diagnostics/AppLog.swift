import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.mactools"

    static let accessibilityPermissionObserver = Logger(subsystem: subsystem, category: "AccessibilityPermissionObserver")
    static let actionGrid = Logger(subsystem: subsystem, category: "ActionGrid")
    static let actionExecution = Logger(subsystem: subsystem, category: "ActionExecution")
    static let appIntents = Logger(subsystem: subsystem, category: "AppIntents")
    static let applicationActivity = Logger(subsystem: subsystem, category: "ApplicationActivity")
    static let appURLRouter = Logger(subsystem: subsystem, category: "AppURLRouter")
    static let instanceCoordination = Logger(subsystem: subsystem, category: "InstanceCoordination")
    static let displayConfigurationObserver = Logger(subsystem: subsystem, category: "DisplayConfigurationObserver")
    static let autoHideDockPlugin = Logger(subsystem: subsystem, category: "AutoHideDockPlugin")
    static let pluginHost = Logger(subsystem: subsystem, category: "PluginHost")
    static let preferencesBackup = Logger(subsystem: subsystem, category: "PreferencesBackup")
    static let launchAtLogin = Logger(subsystem: subsystem, category: "LaunchAtLogin")
    static let releaseHistory = Logger(subsystem: subsystem, category: "ReleaseHistory")

    static var isVerboseLoggingEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACTOOLS_VERBOSE_LOGS"] == "1"
        #else
        false
        #endif
    }
}
