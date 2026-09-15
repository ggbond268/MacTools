@preconcurrency import ApplicationServices
import Foundation

enum AccessibilityCheck {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
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
