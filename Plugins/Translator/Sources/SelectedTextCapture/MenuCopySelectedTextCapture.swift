import AppKit
import Foundation

struct MenuCopySelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .menuCopy

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        failure(context: context, reason: "复制菜单不可用")
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
