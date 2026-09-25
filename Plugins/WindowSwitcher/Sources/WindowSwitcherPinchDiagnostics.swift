import Foundation
import OSLog

/// Opt-in event tracing for physical trackpad diagnosis in the local Debug app.
enum WindowSwitcherPinchDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["MACTOOLS_WINDOW_SWITCHER_PINCH_DIAGNOSTICS"] == "1"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "WindowSwitcherPinch"
    )

    static func record(_ message: String) {
        guard isEnabled else { return }
        logger.info("\(message, privacy: .public)")
    }
}
