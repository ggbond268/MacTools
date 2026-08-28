import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

@MainActor
protocol ClipboardCopyCommandSending {
    /// Calls `beforeSending` immediately before posting Command-C so capture suppression can be
    /// armed without covering the time spent waiting for the shortcut's modifiers to be released.
    func sendCopyCommand(
        to processIdentifier: pid_t,
        beforeSending: () -> Bool
    ) async -> Bool
}

@MainActor
protocol ClipboardPasteCommandSending {
    func sendPasteCommand(to processIdentifier: pid_t, beforeSending: () -> Bool) async -> Bool
}

extension ClipboardPasteCommandSending {
    func sendPasteCommand(to processIdentifier: pid_t) async -> Bool {
        await sendPasteCommand(to: processIdentifier, beforeSending: { true })
    }
}

@MainActor
struct SystemClipboardCopyCommandSender: ClipboardCopyCommandSending {
    func sendCopyCommand(
        to processIdentifier: pid_t,
        beforeSending: () -> Bool
    ) async -> Bool {
        await waitForModifierKeysToClear()

        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: false
              ) else {
            return false
        }

        guard beforeSending(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        // Do not let a rapid sequential-paste request replace the pasteboard payload before the
        // destination application has handled the synthetic Command-V event.
        try? await Task.sleep(for: .milliseconds(120))
        return !Task.isCancelled
    }

    private func waitForModifierKeysToClear() async {
        let trackedModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(0.3)

        while Date() < deadline {
            let current = CGEventSource.flagsState(.combinedSessionState)
            if current.intersection(trackedModifiers).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

@MainActor
struct SystemClipboardPasteCommandSender: ClipboardPasteCommandSending {
    func sendPasteCommand(to processIdentifier: pid_t, beforeSending: () -> Bool) async -> Bool {
        await waitForModifierKeysToClear()
        // Give the previously active application one run-loop turn to regain key focus.
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else {
            return false
        }

        // No suspension between the caller's ownership check and event dispatch.
        guard beforeSending(), !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return false }
        keyDown.setIntegerValueField(.eventSourceUserData, value: SystemClipboardSnippetReplacementAccess.syntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: SystemClipboardSnippetReplacementAccess.syntheticEventMarker)
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }

    private func waitForModifierKeysToClear() async {
        let trackedModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(0.3)

        while Date() < deadline {
            let current = CGEventSource.flagsState(.combinedSessionState)
            if current.intersection(trackedModifiers).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

enum ClipboardHistoryAccessibilityCheck {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestTrust(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
