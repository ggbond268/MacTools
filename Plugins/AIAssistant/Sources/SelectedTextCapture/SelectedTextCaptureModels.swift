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

    init(
        frontmostApplicationBundleID: String? = nil,
        frontmostApplicationLocalizedName: String? = nil
    ) {
        self.frontmostApplicationBundleID = frontmostApplicationBundleID
        self.frontmostApplicationLocalizedName = frontmostApplicationLocalizedName
    }

    init(frontmostApplication: NSRunningApplication?) {
        frontmostApplicationBundleID = frontmostApplication?.bundleIdentifier
        frontmostApplicationLocalizedName = frontmostApplication?.localizedName
    }
}

struct SelectedTextCaptureResult: Equatable, Sendable {
    let text: String?
    let strategyID: SelectedTextCaptureStrategyID?
    let isEditable: Bool
    let sourceApplicationBundleID: String?
    let failureReason: String?

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
