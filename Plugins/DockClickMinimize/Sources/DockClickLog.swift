import Foundation
import OSLog

enum DockClickLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools"

    static let monitor = Logger(subsystem: subsystem, category: "DockClickMonitor")
    static let applicationHider = Logger(subsystem: subsystem, category: "DockClickHide")
}
