import Combine
import XCTest
@testable import MacTools

@MainActor
final class PanelLayoutToolbarTests: XCTestCase {
    func testEditingFeedbackCoalescesRequestsWithoutDelayingLaterAttempts() {
        let feedback = MenuBarPanelEditingFeedback()
        var count = 0
        let subscription = feedback.requests.sink { count += 1 }
        defer { subscription.cancel() }
        let start = ContinuousClock.now
        feedback.request(at: start)
        feedback.request(at: start.advanced(by: .milliseconds(200)))
        feedback.request(at: start.advanced(by: .milliseconds(599)))
        XCTAssertEqual(count, 1)
        feedback.request(at: start.advanced(by: .milliseconds(600)))
        XCTAssertEqual(count, 2, "Ignored requests must not extend the feedback cooldown")
        feedback.reset()
        feedback.request(at: start.advanced(by: .milliseconds(601)))
        XCTAssertEqual(count, 3, "A new editing session can give feedback immediately")
    }
}
