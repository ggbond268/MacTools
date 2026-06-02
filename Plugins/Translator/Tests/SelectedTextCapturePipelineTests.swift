import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class SelectedTextCapturePipelineTests: XCTestCase {
    func testFirstSuccessfulStrategyWins() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .accessibility,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.first",
                    failureReason: "失败"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .menuCopy,
                result: SelectedTextCaptureResult(
                    text: "selected text",
                    strategyID: .menuCopy,
                    isEditable: true,
                    sourceApplicationBundleID: "com.example.second",
                    failureReason: "忽略"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: "later text",
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.third",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result.text, "selected text")
        XCTAssertEqual(result.strategyID, .menuCopy)
        XCTAssertTrue(result.isEditable)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.second")
        XCTAssertNil(result.failureReason)
    }

    func testBlankTextFallsThroughAfterTrimming() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: " \n\t ",
                    strategyID: .accessibility,
                    isEditable: true,
                    sourceApplicationBundleID: "com.example.blank",
                    failureReason: nil
                )
            ),
            StubSelectedTextCapture(
                strategyID: .browserAppleScript,
                result: SelectedTextCaptureResult(
                    text: "browser text",
                    strategyID: .browserAppleScript,
                    isEditable: false,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result.text, "browser text")
        XCTAssertEqual(result.strategyID, .browserAppleScript)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.apple.Safari")
    }

    func testAllFailuresReturnsMissingSelection() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .accessibility,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "失败"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .menuCopy,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .menuCopy,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "复制失败"
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result, .missing)
        XCTAssertEqual(result.failureReason, "未找到选中文本")
    }

    func testPermissionRequiredFailureIsPreservedWhenNoStrategySucceeds() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .accessibility,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.secure",
                    failureReason: "需要辅助功能授权"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .menuCopy,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .menuCopy,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "复制失败"
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertNil(result.text)
        XCTAssertEqual(result.strategyID, .accessibility)
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.secure")
        XCTAssertEqual(result.failureReason, "需要辅助功能授权")
    }

    func testAutomationPermissionRequiredFailureIsPreservedWhenNoStrategySucceeds() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .browserAppleScript,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .browserAppleScript,
                    isEditable: false,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: "需要自动化授权"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "未找到选中文本"
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertNil(result.text)
        XCTAssertEqual(result.strategyID, .browserAppleScript)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.apple.Safari")
        XCTAssertEqual(result.failureReason, "需要自动化授权")
    }

    func testAppleScriptAuthorizationErrorMapsToAutomationPermissionReason() {
        let reason = BrowserAppleScriptSelectedTextCapture.failureReason(
            forAppleScriptError: [NSAppleScript.errorNumber: -1743] as NSDictionary
        )

        XCTAssertEqual(reason, "需要自动化授权")
    }

    func testReturnedTextIsTrimmed() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: "\n  trimmed text \t",
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.app",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result.text, "trimmed text")
        XCTAssertEqual(result.strategyID, .simulatedCopy)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.app")
        XCTAssertNil(result.failureReason)
    }

    func testFirefoxSupportsBrowserAppleScriptSelection() {
        XCTAssertTrue(AppCaptureCompatibility.isBrowser("org.mozilla.firefox"))
        XCTAssertTrue(AppCaptureCompatibility.supportsAppleScriptSelection("org.mozilla.firefox"))
    }

    func testMenuCopyStrategyReturnsFailureForExternalApps() async {
        let result = await MenuCopySelectedTextCapture().capture(
            context: SelectedTextCaptureContext(frontmostApplicationBundleID: "com.example.external")
        )

        XCTAssertNil(result.text)
        XCTAssertEqual(result.strategyID, .menuCopy)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.external")
        XCTAssertEqual(result.failureReason, "复制菜单不可用")
    }
}

private struct StubSelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID
    let result: SelectedTextCaptureResult

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        result
    }
}
