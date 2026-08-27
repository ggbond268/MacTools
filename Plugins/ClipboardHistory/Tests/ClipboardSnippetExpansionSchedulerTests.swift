import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSnippetExpansionSchedulerTests: XCTestCase {
    func testEditorAccessIsDeferredUntilAfterKeyboardCallbackReturns() async throws {
        let scheduler = ClipboardSnippetExpansionScheduler()
        var callbackReturned = false
        var attempts = 0
        scheduler.schedule {
            XCTAssertTrue(callbackReturned, "Never send AX requests while holding the keyboard event")
            attempts += 1
            return .succeeded
        }
        XCTAssertEqual(attempts, 0)
        callbackReturned = true
        for _ in 0..<100 where attempts == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(attempts, 1)
    }

    func testTemporaryFocusFailureCanRetryAfterTheEditorCatchesUp() async throws {
        let scheduler = ClipboardSnippetExpansionScheduler()
        var attempts = 0
        scheduler.schedule {
            attempts += 1
            return attempts < 3 ? .safelyRejectedBeforeMutation : .succeeded
        }
        for _ in 0..<100 where attempts < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(attempts, 3)
    }

    func testNewTypingOrMouseInputCancelsPendingReplacement() async throws {
        let scheduler = ClipboardSnippetExpansionScheduler()
        var attempts = 0
        scheduler.schedule { attempts += 1; return .succeeded }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(attempts, 0)
    }

    func testNewMatchCannotRunThePreviousMatch() async throws {
        let scheduler = ClipboardSnippetExpansionScheduler()
        var first = 0
        var second = 0
        scheduler.schedule { first += 1; return .succeeded }
        scheduler.schedule { second += 1; return .succeeded }
        for _ in 0..<100 where second == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    func testUncertainMutationNeverRetries() async throws {
        let scheduler = ClipboardSnippetExpansionScheduler()
        var attempts = 0
        scheduler.schedule { attempts += 1; return .consumedAfterMutation }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 1)
    }

    func testUnavailableEditorStopsAfterBoundedRetries() async throws {
        let scheduler = ClipboardSnippetExpansionScheduler()
        var attempts = 0
        scheduler.schedule { attempts += 1; return .safelyRejectedBeforeMutation }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 3)
    }
}
