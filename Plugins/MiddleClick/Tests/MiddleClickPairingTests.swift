import CoreGraphics
import XCTest
@testable import MacTools
@testable import MiddleClickPlugin

/// Covers the down→up pairing state machine, including the macOS 27 beta
/// failure mode where a converted down's paired up never reaches the tap
/// (e.g. the rewritten otherMouseDown targets the synthesized menu bar
/// window): a stale armed flag must not turn the next ordinary click into a
/// middle-click.
final class MiddleClickPairingTests: XCTestCase {

    /// Drives `MiddleClickPairing.decide` the same way the tap callback does:
    /// holds the flags across events and lets tests simulate the multitouch
    /// callback flipping `threeDown`.
    private struct TapSimulator {
        var state = MiddleClickPairing.State(threeDown: false, wasThreeDown: false)

        mutating func setFingersMatchRequiredCount(_ matches: Bool) {
            state.threeDown = matches
        }

        mutating func send(_ type: CGEventType) -> MiddleClickPairing.Rewrite {
            let decision = MiddleClickPairing.decide(type: type, state: state)
            state = decision.state
            return decision.rewrite
        }
    }

    // MARK: - Normal pairing

    func testThreeFingerDownIsRewrittenAndArms() {
        var tap = TapSimulator()
        tap.setFingersMatchRequiredCount(true)

        XCTAssertEqual(tap.send(.leftMouseDown), .middleDown)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: true))
    }

    func testArmedUpIsRewrittenAndDisarms() {
        var tap = TapSimulator()
        tap.state = .init(threeDown: false, wasThreeDown: true)

        XCTAssertEqual(tap.send(.leftMouseUp), .middleUp)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
    }

    func testRightDownWithThreeFingersIsRewritten() {
        var tap = TapSimulator()
        tap.setFingersMatchRequiredCount(true)

        XCTAssertEqual(tap.send(.rightMouseDown), .middleDown)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: true))
    }

    func testRightUpWhileArmedIsRewrittenSameAsLeftUp() {
        var tap = TapSimulator()
        tap.state = .init(threeDown: false, wasThreeDown: true)

        XCTAssertEqual(tap.send(.rightMouseUp), .middleUp)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
    }

    func testOrdinaryClickPassesThroughWhenDisarmed() {
        var tap = TapSimulator()

        XCTAssertEqual(tap.send(.leftMouseDown), MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(tap.send(.leftMouseUp), MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
    }

    // MARK: - Lost-up recovery

    func testLostUpThenOrdinaryClickDisarmsAndPassesThrough() {
        var tap = TapSimulator()
        tap.setFingersMatchRequiredCount(true)
        XCTAssertEqual(tap.send(.leftMouseDown), .middleDown)
        // Paired up is lost; the next event is an ordinary single-finger click.

        XCTAssertEqual(tap.send(.leftMouseDown), MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
        XCTAssertEqual(tap.send(.leftMouseUp), MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
    }

    func testLostUpThenOrdinaryRightClickDisarmsAndPassesThrough() {
        var tap = TapSimulator()
        tap.state = .init(threeDown: false, wasThreeDown: true)

        XCTAssertEqual(tap.send(.rightMouseDown), MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
        XCTAssertEqual(tap.send(.rightMouseUp), MiddleClickPairing.Rewrite.none)
    }

    func testLostUpThenThreeFingerDownRearms() {
        var tap = TapSimulator()
        tap.state = .init(threeDown: false, wasThreeDown: true)
        tap.setFingersMatchRequiredCount(true)

        XCTAssertEqual(tap.send(.leftMouseDown), .middleDown)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: true))
        XCTAssertEqual(tap.send(.leftMouseUp), .middleUp)
        XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
    }

    // MARK: - Sequences

    func testConsecutiveThreeFingerClicksDoNotInterfere() {
        var tap = TapSimulator()

        for _ in 0..<3 {
            tap.setFingersMatchRequiredCount(true)
            XCTAssertEqual(tap.send(.leftMouseDown), .middleDown)
            tap.setFingersMatchRequiredCount(false)
            XCTAssertEqual(tap.send(.leftMouseUp), .middleUp)
            XCTAssertEqual(tap.state, .init(threeDown: false, wasThreeDown: false))
        }
    }

    func testOrdinaryClickAfterCompletedPairPassesThrough() {
        var tap = TapSimulator()
        tap.setFingersMatchRequiredCount(true)
        XCTAssertEqual(tap.send(.leftMouseDown), .middleDown)
        XCTAssertEqual(tap.send(.leftMouseUp), .middleUp)

        XCTAssertEqual(tap.send(.leftMouseDown), MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(tap.send(.leftMouseUp), MiddleClickPairing.Rewrite.none)
    }

    // MARK: - Unrelated callback types

    func testTapDisabledCallbackDoesNotDisturbPairingState() {
        let armed = MiddleClickPairing.State(threeDown: false, wasThreeDown: true)

        let decision = MiddleClickPairing.decide(type: .tapDisabledByTimeout, state: armed)

        XCTAssertEqual(decision.rewrite, MiddleClickPairing.Rewrite.none)
        XCTAssertEqual(decision.state, armed)
    }
}
