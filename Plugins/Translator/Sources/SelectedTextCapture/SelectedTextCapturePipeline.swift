import Foundation

@MainActor
struct SelectedTextCapturePipeline {
    let strategies: [any SelectedTextCapturing]

    static func live() -> SelectedTextCapturePipeline {
        SelectedTextCapturePipeline(strategies: [
            AccessibilitySelectedTextCapture(),
            BrowserAppleScriptSelectedTextCapture(),
            MenuCopySelectedTextCapture(),
            SimulatedCopySelectedTextCapture(),
        ])
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        var permissionRequiredResult: SelectedTextCaptureResult?
        var automationPermissionRequiredResult: SelectedTextCaptureResult?

        for strategy in strategies {
            let result = await strategy.capture(context: context)
            let trimmedText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedText.isEmpty else {
                if permissionRequiredResult == nil,
                   result.failureReason == "需要辅助功能授权" {
                    permissionRequiredResult = result
                }

                if automationPermissionRequiredResult == nil,
                   result.failureReason == "需要自动化授权" {
                    automationPermissionRequiredResult = result
                }

                continue
            }

            return SelectedTextCaptureResult(
                text: trimmedText,
                strategyID: result.strategyID,
                isEditable: result.isEditable,
                sourceApplicationBundleID: result.sourceApplicationBundleID,
                failureReason: nil
            )
        }

        if let permissionRequiredResult {
            return permissionRequiredResult
        }

        if let automationPermissionRequiredResult {
            return automationPermissionRequiredResult
        }

        return .missing
    }
}
