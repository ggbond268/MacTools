import AppKit
import ApplicationServices
import Carbon
import Foundation
import MacToolsPluginKit

struct SimulatedCopySelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .simulatedCopy
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        guard AccessibilityCheck.isTrusted() else {
            return failure(
                context: context,
                reason: localization.string("capture.error.permissionRequired", defaultValue: "需要辅助功能授权")
            )
        }

        await waitForModifierKeysToClear()

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount
        guard sendCommandC() else {
            guard snapshot.restore(to: pasteboard) else {
                return failure(
                    context: context,
                    reason: localization.string("capture.error.restorePasteboardFailed", defaultValue: "无法恢复剪贴板")
                )
            }
            return failure(
                context: context,
                reason: localization.string("capture.error.simulatedCopyFailed", defaultValue: "模拟复制失败")
            )
        }

        await waitForPasteboardChange(from: clearedChangeCount, in: pasteboard)
        let text = pasteboard.string(forType: .string)
        guard snapshot.restore(to: pasteboard) else {
            return failure(
                context: context,
                reason: localization.string("capture.error.restorePasteboardFailed", defaultValue: "无法恢复剪贴板")
            )
        }

        guard let text, !text.isEmpty else {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        return SelectedTextCaptureResult(
            text: text,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: nil
        )
    }

    private func waitForPasteboardChange(from clearedChangeCount: Int, in pasteboard: NSPasteboard) async {
        let deadline = Date().addingTimeInterval(0.8)
        while pasteboard.changeCount == clearedChangeCount && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        if pasteboard.changeCount != clearedChangeCount {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
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

    private func sendCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
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

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func failure(context: SelectedTextCaptureContext, reason: String) -> SelectedTextCaptureResult {
        SelectedTextCaptureResult(
            text: nil,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: reason
        )
    }
}
