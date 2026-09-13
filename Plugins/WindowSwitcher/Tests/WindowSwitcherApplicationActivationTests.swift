import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherApplicationActivationTests: XCTestCase {
    private final class Fixture {
        var value = WindowSwitcherApplicationActivation.State(isHidden: true, isFrontmost: false)
        var requests: [WindowSwitcherApplicationActivation.Request] = []
    }

    func testActivationWaitsForUnhideAndDoesNotRepeatRequests() async {
        let fixture = Fixture()
        var unhideReads = 0, activationReads = 0
        let result = await WindowSwitcherApplicationActivation.prepare(state: {
            if fixture.requests.last == .unhide {
                unhideReads += 1
                if unhideReads >= 3 { fixture.value.isHidden = false }
            }
            if fixture.requests.last == .activate {
                activationReads += 1
                if activationReads >= 3 { fixture.value.isFrontmost = true }
            }
            return fixture.value
        }, request: { request in
            if request == .activate { XCTAssertFalse(fixture.value.isHidden) }
            fixture.requests.append(request)
        })
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(fixture.requests, [.unhide, .activate])
    }

    func testAlreadyForegroundApplicationNeedsNoActivationRequest() async {
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: false, isFrontmost: true) }, request: { _ in XCTFail("Already ready") })
        XCTAssertEqual(result, .succeeded)
    }

    func testOtherSpaceWindowRequestsOneActivationEvenForForegroundApp() async {
        var requests: [WindowSwitcherApplicationActivation.Request] = []
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: false, isFrontmost: true) },
            request: { requests.append($0) }, activateAllSpaces: true)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(requests, [.activate])
    }

    func testUnconfirmedActivationFailsWithoutRetryingRequest() async {
        let fixture = Fixture()
        fixture.value.isHidden = false
        let result = await WindowSwitcherApplicationActivation.prepare(state: { fixture.value },
            request: { fixture.requests.append($0) }, timeout: .milliseconds(50))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fixture.requests, [.activate])
    }

    func testCancellationDuringUnhidePreventsActivation() async {
        let fixture = Fixture()
        let requested = expectation(description: "unhide requested")
        let operation = Task {
            await WindowSwitcherApplicationActivation.prepare(state: { fixture.value }, request: {
                fixture.requests.append($0); requested.fulfill()
            })
        }
        await fulfillment(of: [requested], timeout: 1)
        operation.cancel()
        let result = await operation.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(fixture.requests, [.unhide])
    }

    func testTerminatedApplicationNeverReceivesActivation() async {
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: true, isFrontmost: false, isTerminated: true) }, request: { _ in XCTFail("Terminated") })
        XCTAssertEqual(result, .unavailable)
    }
    func testAcceptedNativeRequestUsesOneFallbackOnlyWhenStillNotFrontmost() async {
        var frontmost = false
        var nativeRequests = 0, fallbacks = 0
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: false, isFrontmost: frontmost) },
            request: { _ in nativeRequests += 1 }, fallbackRequest: {
                fallbacks += 1; frontmost = true
            }, fallbackDelay: .zero)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(nativeRequests, 1)
        XCTAssertEqual(fallbacks, 1)
    }

    func testNativeSuccessDoesNotUseFallback() async {
        var frontmost = false
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: false, isFrontmost: frontmost) },
            request: { _ in frontmost = true }, fallbackRequest: { XCTFail("Already activated") }, fallbackDelay: .zero)
        XCTAssertEqual(result, .succeeded)
    }

    func testUserSwitchingElsewhereCancelsBeforeFallback() async {
        var currentIntent = true
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: false, isFrontmost: false) },
            request: { _ in currentIntent = false }, fallbackRequest: { XCTFail("User moved on") },
            fallbackDelay: .zero, shouldContinue: { currentIntent })
        XCTAssertEqual(result, .cancelled)
    }

    func testUnsuccessfulFallbackIsNotRepeated() async {
        var fallbacks = 0
        let result = await WindowSwitcherApplicationActivation.prepare(
            state: { .init(isHidden: false, isFrontmost: false) }, request: { _ in },
            timeout: .milliseconds(50), fallbackRequest: { fallbacks += 1 }, fallbackDelay: .zero)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fallbacks, 1)
    }

}
