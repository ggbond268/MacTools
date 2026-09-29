import OSLog

enum DuoStatusLog {
    static let audioEvent = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DuoStatusAudioEvent"
    )
    static let monitor = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DuoStatusMonitor"
    )
}
