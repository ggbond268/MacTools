import Foundation
import os

enum AIAssistantLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools"

    static let capture = Logger(subsystem: subsystem, category: "AIAssistantCapture")
    static let provider = Logger(subsystem: subsystem, category: "AIAssistantProvider")
}
