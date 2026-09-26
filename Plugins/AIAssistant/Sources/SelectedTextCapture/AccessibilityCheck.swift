@preconcurrency import ApplicationServices
import Foundation

enum AccessibilityCheck {
    /// Injectable trust probe so capture tests can simulate both trust states
    /// without changing the test runner's system permissions. Always restore
    /// the default in test teardown.
    nonisolated(unsafe) static var trustProbe: () -> Bool = { AXIsProcessTrusted() }

    static func isTrusted() -> Bool {
        trustProbe()
    }

    static func requestTrust(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
