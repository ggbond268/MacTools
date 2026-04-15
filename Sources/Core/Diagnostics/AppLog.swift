import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.mactools"

    static let keepAwakePlugin = Logger(subsystem: subsystem, category: "KeepAwakePlugin")
    static let keepAwakeSession = Logger(subsystem: subsystem, category: "KeepAwakeSession")
    static let physicalCleanModePlugin = Logger(subsystem: subsystem, category: "PhysicalCleanModePlugin")
    static let physicalCleanModeSession = Logger(subsystem: subsystem, category: "PhysicalCleanModeSession")
    static let displayResolutionPlugin = Logger(subsystem: subsystem, category: "DisplayResolutionPlugin")
    static let displayResolutionController = Logger(subsystem: subsystem, category: "DisplayResolutionController")

    static var isVerboseLoggingEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACTOOLS_VERBOSE_LOGS"] == "1"
        #else
        false
        #endif
    }
}
