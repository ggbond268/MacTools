import ApplicationServices
import Foundation
import XCTest
@testable import SiriPlugin

@MainActor
final class SiriAccessibilityClientTests: XCTestCase {
    func testFailedOrMalformedDraftReadNeverWrites() {
        let input = AXUIElementCreateApplication(42)
        let responses: [(AXError, CFTypeRef?)] = [
            (.cannotComplete, nil), (.invalidUIElement, nil), (.apiDisabled, nil),
            (.noValue, nil), (.attributeUnsupported, nil), (.success, nil), (.success, 123 as CFNumber),
        ]
        for (error, value) in responses {
            let messaging = FakeSiriAXMessaging()
            messaging.respond(to: kAXValueAttribute, error: error, value: value)
            let access = SiriAXAccess(messaging: messaging)
            XCTAssertThrowsError(try access.enterText("automation message", into: input, deadline: .now + .seconds(5)))
            XCTAssertFalse(messaging.events.contains { $0.kind == "set" }, "Failed read: \(error)")
        }
    }

    func testExistingDraftIsPreservedAndConfirmedEmptyInputCanBeWritten() throws {
        let input = AXUIElementCreateApplication(42)
        let messaging = FakeSiriAXMessaging()
        let access = SiriAXAccess(messaging: messaging)
        messaging.respond(to: kAXValueAttribute, value: "user draft" as CFString)
        XCTAssertThrowsError(try access.enterText("automation", into: input, deadline: .now + .seconds(5))) {
            XCTAssertEqual($0 as? SiriFailure, .existingDraft)
        }
        XCTAssertFalse(messaging.events.contains { $0.kind == "set" })
        messaging.respond(to: kAXValueAttribute, value: "" as CFString)
        try access.enterText("  exact\n消息  ", into: input, deadline: .now + .seconds(5))
        XCTAssertEqual(messaging.writtenText, "  exact\n消息  ")
    }

    func testUnavailableLeafChildrenAreAllowedButContainerAndMessagingFailuresAreNot() throws {
        let element = AXUIElementCreateApplication(42)
        for error in [AXError.attributeUnsupported, .noValue] {
            let messaging = FakeSiriAXMessaging()
            messaging.respond(to: kAXChildrenAttribute, error: error)
            let access = SiriAXAccess(messaging: messaging)
            for role in [kAXStaticTextRole, kAXValueIndicatorRole, kAXSplitterRole] {
                XCTAssertTrue(try access.children(element, role: role, deadline: .now + .seconds(5)).isEmpty)
            }
            XCTAssertThrowsError(try access.children(element, role: kAXGroupRole, deadline: .now + .seconds(5)))
        }
        let messaging = FakeSiriAXMessaging()
        messaging.respond(to: kAXChildrenAttribute, error: .cannotComplete)
        let access = SiriAXAccess(messaging: messaging)
        XCTAssertThrowsError(try access.children(element, role: kAXStaticTextRole, deadline: .now + .seconds(5)))
        XCTAssertThrowsError(try access.children(element, role: kAXValueIndicatorRole, deadline: .now + .seconds(5)))
        XCTAssertThrowsError(try access.children(element, role: kAXSplitterRole, deadline: .now + .seconds(5)))
        XCTAssertThrowsError(try access.children(element, role: kAXGroupRole, deadline: .now + .seconds(5)))
        messaging.respond(to: kAXChildrenAttribute, value: [] as CFArray)
        XCTAssertTrue(try access.children(element, role: kAXGroupRole, deadline: .now + .seconds(5)).isEmpty)
    }

    func testEveryReadCapabilityWriteAndActionSetsTimeoutOnTheExactObject() throws {
        // Equal AX wrappers still require their own timeout; neither application nor wrapper settings propagate.
        let first = AXUIElementCreateApplication(42)
        let second = AXUIElementCreateApplication(42)
        let messaging = FakeSiriAXMessaging()
        messaging.respond(to: kAXValueAttribute, value: "" as CFString)
        let access = SiriAXAccess(messaging: messaging)
        let deadline = ContinuousClock.now + .seconds(5)
        _ = try access.string(first, kAXValueAttribute, deadline: deadline)
        try access.requireWritableInput(second, deadline: deadline)
        try access.enterText("message", into: second, deadline: deadline)
        try access.perform("AXConfirm", on: first, deadline: deadline, failure: .submissionUncertain)
        let events = messaging.events
        XCTAssertEqual(events.count, 12)
        for index in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[index].kind, "timeout")
            XCTAssertNotEqual(events[index + 1].kind, "timeout")
            XCTAssertEqual(Unmanaged.passUnretained(events[index].element).toOpaque(),
                           Unmanaged.passUnretained(events[index + 1].element).toOpaque())
            XCTAssertEqual(events[index].seconds, 0.5)
        }
    }

    func testRemainingDeadlineBoundsEachCallAndExpirationPreventsMoreWork() throws {
        let instant = ContinuousClock.now
        let clock = SiriAXTestClock(instant)
        let messaging = FakeSiriAXMessaging()
        messaging.respond(to: kAXValueAttribute, value: "" as CFString)
        let access = SiriAXAccess(messaging: messaging, now: { clock.now })
        let input = AXUIElementCreateApplication(42)
        _ = try access.string(input, kAXValueAttribute, deadline: instant + .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(messaging.events.first?.seconds), 0.1, accuracy: 0.0001)
        let count = messaging.events.count
        clock.advance(by: .seconds(1))
        XCTAssertThrowsError(try access.enterText("message", into: input, deadline: instant + .milliseconds(100))) {
            XCTAssertEqual($0 as? SiriFailure, .timedOut)
        }
        XCTAssertEqual(messaging.events.count, count)
    }

    func testReadCompletingAfterDeadlineCannotProceedToWrite() {
        let instant = ContinuousClock.now
        let clock = SiriAXTestClock(instant)
        let messaging = FakeSiriAXMessaging(afterRead: { clock.advance(by: .seconds(1)) })
        messaging.respond(to: kAXValueAttribute, value: "" as CFString)
        let access = SiriAXAccess(messaging: messaging, now: { clock.now })
        XCTAssertThrowsError(try access.enterText("message", into: AXUIElementCreateApplication(42),
                                               deadline: instant + .milliseconds(100))) {
            XCTAssertEqual($0 as? SiriFailure, .timedOut)
        }
        XCTAssertFalse(messaging.events.contains { $0.kind == "set" })
    }

    func testTimeoutConfigurationFailurePreventsMessaging() {
        let messaging = FakeSiriAXMessaging(timeoutError: .invalidUIElement)
        let access = SiriAXAccess(messaging: messaging)
        XCTAssertThrowsError(try access.perform("AXConfirm", on: AXUIElementCreateApplication(42),
                                              deadline: .now + .seconds(5), failure: .submissionUncertain))
        XCTAssertEqual(messaging.events.map(\.kind), ["timeout"])
    }

    func testCancellationPreventsReadsAndWrites() async {
        let messaging = FakeSiriAXMessaging()
        let task = Task { @MainActor in
            do {
                try SiriAXAccess(messaging: messaging).enterText("message", into: AXUIElementCreateApplication(42),
                                                               deadline: .now + .seconds(5))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(messaging.events.isEmpty)
    }

    func testVerificationRetriesFailedReadUntilExactEvidenceAppears() async throws {
        let instant = ContinuousClock.now
        let clock = SiriAXTestClock(instant)
        var reads = 0
        var pauses = 0
        let message = "exact message"
        try await SiriSubmissionVerification.wait(deadline: instant + .seconds(1), now: { clock.now }, sleep: {
            pauses += 1
            clock.advance(by: $0)
        }) {
            reads += 1
            if reads == 1 { throw SiriFailure.missingControls }
            let visibleMessages = reads == 2 ? ["different message"] : [message]
            return visibleMessages == [message]
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(pauses, 2)
    }

    func testPermanentVerificationReadFailureStopsAtDeadline() async {
        let instant = ContinuousClock.now
        let clock = SiriAXTestClock(instant)
        var reads = 0
        do {
            try await SiriSubmissionVerification.wait(deadline: instant + .milliseconds(300), now: { clock.now },
                                                       sleep: { clock.advance(by: $0) }) {
                reads += 1
                throw SiriFailure.missingControls
            }
            XCTFail("Failed reads cannot establish delivery")
        } catch {
            XCTAssertEqual(error as? SiriFailure, .timedOut)
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(clock.now, instant + .milliseconds(300))
    }

    func testVerificationDoesNotRetryDestinationPermissionTimeoutOrCancellationErrors() async {
        let errors: [any Error] = [SiriFailure.destinationChanged, SiriFailure.permission,
                                   SiriFailure.timedOut, CancellationError()]
        for expected in errors {
            var reads = 0
            var pauses = 0
            do {
                try await SiriSubmissionVerification.wait(deadline: .now + .seconds(5), sleep: { _ in pauses += 1 }) {
                    reads += 1
                    throw expected
                }
                XCTFail("The error should propagate")
            } catch {
                if expected is CancellationError { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? SiriFailure, expected as? SiriFailure) }
            }
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(pauses, 0)
        }
    }

    func testVerificationRejectsEvidenceReadAfterDeadline() async {
        let instant = ContinuousClock.now
        let clock = SiriAXTestClock(instant)
        do {
            try await SiriSubmissionVerification.wait(deadline: instant + .milliseconds(100), now: { clock.now }) {
                clock.advance(by: .seconds(1))
                return true
            }
            XCTFail("Late evidence must not bypass the deadline")
        } catch {
            XCTAssertEqual(error as? SiriFailure, .timedOut)
        }
    }
}

private final class SiriAXTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant
    init(_ instant: ContinuousClock.Instant) { self.instant = instant }
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant += duration } }
}

private final class FakeSiriAXMessaging: SiriAXMessaging, @unchecked Sendable {
    struct Event {
        let kind: String
        let element: AXUIElement
        var seconds: Float? = nil
    }
    private let lock = NSLock()
    private var recordedEvents: [Event] = []
    private var responses: [String: (AXError, CFTypeRef?)] = [:]
    private var text: String?
    private let timeoutError: AXError
    private let afterRead: @Sendable () -> Void
    init(timeoutError: AXError = .success, afterRead: @escaping @Sendable () -> Void = {}) {
        self.timeoutError = timeoutError
        self.afterRead = afterRead
    }
    var events: [Event] { lock.withLock { recordedEvents } }
    var writtenText: String? { lock.withLock { text } }
    func respond(to name: String, error: AXError = .success, value: CFTypeRef? = nil) {
        lock.withLock { responses[name] = (error, value) }
    }
    func setTimeout(_ element: AXUIElement, seconds: Float) -> AXError {
        lock.withLock { recordedEvents.append(Event(kind: "timeout", element: element, seconds: seconds)) }
        return timeoutError
    }
    func copyAttribute(_ element: AXUIElement, name: String) -> (AXError, CFTypeRef?) {
        let result = lock.withLock {
            recordedEvents.append(Event(kind: "read", element: element))
            return responses[name] ?? (.attributeUnsupported, nil)
        }
        afterRead()
        return result
    }
    func isSettable(_ element: AXUIElement, name: String) -> (AXError, Bool) {
        lock.withLock { recordedEvents.append(Event(kind: "settable", element: element)) }
        return (.success, true)
    }
    func actionNames(_ element: AXUIElement) -> (AXError, [String]?) {
        lock.withLock { recordedEvents.append(Event(kind: "actions", element: element)) }
        return (.success, ["AXConfirm"])
    }
    func setValue(_ element: AXUIElement, name: String, value: CFTypeRef) -> AXError {
        lock.withLock {
            recordedEvents.append(Event(kind: "set", element: element))
            text = value as? String
        }
        return .success
    }
    func perform(_ element: AXUIElement, action: String) -> AXError {
        lock.withLock { recordedEvents.append(Event(kind: "perform", element: element)) }
        return .success
    }
}
