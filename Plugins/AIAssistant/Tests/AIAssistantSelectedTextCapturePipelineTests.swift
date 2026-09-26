import XCTest
@testable import AIAssistantPlugin

@MainActor
final class AIAssistantSelectedTextCapturePipelineTests: XCTestCase {
    func testConsentRevokedDuringEarlierCapturePreventsSimulatedCopy() async {
        let copy = CountingSimulatedCopy()
        var enabled = true
        let pipeline = SelectedTextCapturePipeline(
            strategies: [RevokingCapture { enabled = false }, copy],
            allowsSimulatedCopy: { enabled }
        )
        let result = await pipeline.capture(context: SelectedTextCaptureContext())
        XCTAssertNil(result.text)
        XCTAssertEqual(copy.callCount, 0)
    }

    func testSimulatedCopyRequiresExplicitOptIn() async {
        let copy = CountingSimulatedCopy()
        var enabled = false
        let pipeline = SelectedTextCapturePipeline(
            strategies: [copy], allowsSimulatedCopy: { enabled }
        )
        let context = SelectedTextCaptureContext()

        let disabledResult = await pipeline.capture(context: context)
        XCTAssertNil(disabledResult.text)
        XCTAssertEqual(copy.callCount, 0)

        enabled = true
        let enabledResult = await pipeline.capture(context: context)
        XCTAssertEqual(enabledResult.text, "copied")
        XCTAssertEqual(copy.callCount, 1)
    }
}

@MainActor
private struct RevokingCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .accessibility
    let revoke: () -> Void
    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        await Task.yield()
        revoke()
        return .missing
    }
}

@MainActor
private final class CountingSimulatedCopy: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .simulatedCopy
    var callCount = 0

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        callCount += 1
        return SelectedTextCaptureResult(
            text: "copied", strategyID: strategyID, isEditable: false,
            sourceApplicationBundleID: nil, failureReason: nil
        )
    }
}
