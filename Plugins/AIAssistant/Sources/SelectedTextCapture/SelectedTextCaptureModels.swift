import AppKit
import Foundation
import MacToolsPluginKit

enum SelectedTextCaptureStrategyID: String, Equatable, Sendable {
    case accessibility
    case browserAppleScript
    case simulatedCopy
}

struct SelectedTextCaptureContext: Sendable {
    let frontmostApplicationBundleID: String?
    let frontmostApplicationLocalizedName: String?
    let frontmostApplicationProcessIdentifier: pid_t?

    init(
        frontmostApplicationBundleID: String? = nil,
        frontmostApplicationLocalizedName: String? = nil,
        frontmostApplicationProcessIdentifier: pid_t? = nil
    ) {
        self.frontmostApplicationBundleID = frontmostApplicationBundleID
        self.frontmostApplicationLocalizedName = frontmostApplicationLocalizedName
        self.frontmostApplicationProcessIdentifier = frontmostApplicationProcessIdentifier
    }

    init(frontmostApplication: NSRunningApplication?) {
        frontmostApplicationBundleID = frontmostApplication?.bundleIdentifier
        frontmostApplicationLocalizedName = frontmostApplication?.localizedName
        frontmostApplicationProcessIdentifier = frontmostApplication?.processIdentifier
    }
}

struct SelectedTextCaptureResult: Equatable, Sendable {
    let text: String?
    let strategyID: SelectedTextCaptureStrategyID?
    let isEditable: Bool
    let sourceApplicationBundleID: String?
    let failureReason: String?
    /// True when the text was read from the pasteboard without a verified
    /// owner (the simulated-copy fallback). A change count alone cannot prove
    /// who wrote the content, so the caller must ask the user to confirm this
    /// text before sending it anywhere.
    let requiresUserConfirmation: Bool

    init(
        text: String?,
        strategyID: SelectedTextCaptureStrategyID?,
        isEditable: Bool,
        sourceApplicationBundleID: String?,
        failureReason: String?,
        requiresUserConfirmation: Bool = false
    ) {
        self.text = text
        self.strategyID = strategyID
        self.isEditable = isEditable
        self.sourceApplicationBundleID = sourceApplicationBundleID
        self.failureReason = failureReason
        self.requiresUserConfirmation = requiresUserConfirmation
    }

    static let missing = missing()

    static func missing(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> SelectedTextCaptureResult {
        SelectedTextCaptureResult(
            text: nil,
            strategyID: nil,
            isEditable: false,
            sourceApplicationBundleID: nil,
            failureReason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
        )
    }
}

@MainActor
protocol SelectedTextCapturing {
    var strategyID: SelectedTextCaptureStrategyID { get }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult
}
