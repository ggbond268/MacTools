import Foundation
import MacToolsPluginKit

@MainActor
struct SelectedTextCapturePipeline: SelectedTextCaptureProviding {
    let strategies: [any SelectedTextCapturing]
    private let localization: PluginLocalization

    init(
        strategies: [any SelectedTextCapturing],
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.strategies = strategies
        self.localization = localization
    }

    static func live(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> SelectedTextCapturePipeline {
        SelectedTextCapturePipeline(strategies: [
            AccessibilitySelectedTextCapture(localization: localization),
            BrowserAppleScriptSelectedTextCapture(localization: localization),
            SimulatedCopySelectedTextCapture(localization: localization),
        ], localization: localization)
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        if AppCaptureCompatibility.supportsAppleScriptSelection(context.frontmostApplicationBundleID) {
            return await captureBrowserSelection(context: context)
        }

        return await captureInOrder(strategies: strategies, context: context)
    }

    private func captureBrowserSelection(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        let browserStrategy = strategies.first { $0.strategyID == .browserAppleScript }
        let fallbackStrategies = strategies.filter { $0.strategyID != .browserAppleScript }

        if let browserStrategy {
            let result = await browserStrategy.capture(context: context)
            if let success = successfulResult(from: result) {
                return success
            }
        }

        return await captureInOrder(strategies: fallbackStrategies, context: context)
    }

    private func captureInOrder(
        strategies: [any SelectedTextCapturing],
        context: SelectedTextCaptureContext
    ) async -> SelectedTextCaptureResult {
        var permissionRequiredResult: SelectedTextCaptureResult?
        let permissionRequiredMessage = AIAssistantPanelError.permissionRequired.message(localization: localization)

        for strategy in strategies {
            let result = await strategy.capture(context: context)
            guard let success = successfulResult(from: result) else {
                if permissionRequiredResult == nil,
                   result.failureReason == permissionRequiredMessage {
                    permissionRequiredResult = result
                }

                continue
            }

            return success
        }

        if let permissionRequiredResult {
            return permissionRequiredResult
        }

        return .missing(localization: localization)
    }

    private func successfulResult(from result: SelectedTextCaptureResult) -> SelectedTextCaptureResult? {
        let trimmedText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedText.isEmpty else {
            return nil
        }

        return SelectedTextCaptureResult(
            text: trimmedText,
            strategyID: result.strategyID,
            isEditable: result.isEditable,
            sourceApplicationBundleID: result.sourceApplicationBundleID,
            failureReason: nil
        )
    }
}
