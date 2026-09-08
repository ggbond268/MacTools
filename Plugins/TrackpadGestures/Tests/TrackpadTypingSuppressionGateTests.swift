import XCTest
@testable import TrackpadGesturesPlugin

final class TrackpadTypingSuppressionGateTests: XCTestCase {
    func testDefaultGracePeriodSuppressesWhileHeldAndForFourTenthsAfterKeyUp() {
        let gate = TrackpadTypingSuppressionGate()

        gate.observeKeyDown(keyCode: 0, at: 1.0)
        XCTAssertTrue(gate.shouldSuppress(at: 4.9))

        gate.observeKeyUp(keyCode: 0, at: 4.9)
        XCTAssertTrue(gate.shouldSuppress(at: 5.299))
        XCTAssertFalse(gate.shouldSuppress(at: 5.301))
    }

    func testRepeatedAndOverlappingKeysExtendSuppressionUntilEveryKeyIsReleased() {
        let gate = TrackpadTypingSuppressionGate()
        gate.update(isEnabled: true, gracePeriod: 0.2)

        gate.observeKeyDown(keyCode: 0, at: 1.0)
        gate.observeKeyDown(keyCode: 1, at: 1.1)
        gate.observeKeyDown(keyCode: 0, at: 1.2)
        gate.observeKeyUp(keyCode: 0, at: 1.3)
        XCTAssertTrue(gate.shouldSuppress(at: 5.0), "the second key remains held")

        gate.observeKeyUp(keyCode: 1, at: 5.0)
        XCTAssertTrue(gate.shouldSuppress(at: 5.199))
        XCTAssertFalse(gate.shouldSuppress(at: 5.2))
    }

    func testMissedKeyUpCannotSuppressGesturesForever() {
        let gate = TrackpadTypingSuppressionGate()

        gate.observeKeyDown(keyCode: 0, at: 1.0)

        XCTAssertTrue(gate.shouldSuppress(at: 5.999))
        XCTAssertFalse(gate.shouldSuppress(at: 6.0))
    }

    func testRepeatedKeyDownRefreshesHeldKeyLifetime() {
        let gate = TrackpadTypingSuppressionGate()

        gate.observeKeyDown(keyCode: 0, at: 1.0)
        gate.observeKeyDown(keyCode: 0, at: 5.0)

        XCTAssertTrue(gate.shouldSuppress(at: 9.999))
        XCTAssertFalse(gate.shouldSuppress(at: 10.0))
    }

    func testDisablingAndResettingClearHeldKeyState() {
        let gate = TrackpadTypingSuppressionGate()
        gate.observeKeyDown(keyCode: 0, at: 1.0)

        gate.update(isEnabled: false, gracePeriod: 0.4)
        XCTAssertFalse(gate.shouldSuppress(at: 1.1))

        gate.update(isEnabled: true, gracePeriod: 0.4)
        gate.observeKeyDown(keyCode: 0, at: 2.0)
        gate.reset()
        XCTAssertFalse(gate.shouldSuppress(at: 2.1))
    }

    func testGracePeriodIsClampedToSupportedRange() {
        XCTAssertEqual(TrackpadTypingSuppressionGate.clamped(0), 0.2)
        XCTAssertEqual(TrackpadTypingSuppressionGate.clamped(0.6), 0.6)
        XCTAssertEqual(TrackpadTypingSuppressionGate.clamped(2), 1.0)
    }

    func testContactResetRequiresEveryOccupiedDeviceToReachZero() {
        let gate = TrackpadContactResetGate()
        let occupiedDeviceOne = TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)]
        )
        let occupiedDeviceTwo = TrackpadContactFrame(
            deviceID: 2,
            timestamp: 0,
            contacts: [.init(identifier: 2, x: 0.5, y: 0.5)]
        )

        gate.beginSuppression(activeDeviceIDs: [1])
        XCTAssertTrue(gate.shouldSuppress(occupiedDeviceOne, while: false))
        XCTAssertTrue(gate.shouldSuppress(occupiedDeviceTwo, while: true))
        XCTAssertTrue(gate.shouldSuppress(occupiedDeviceTwo, while: false))
        XCTAssertTrue(gate.shouldSuppress(
            .init(deviceID: 1, timestamp: 0.1, contacts: []),
            while: false
        ))
        XCTAssertTrue(gate.shouldSuppress(
            .init(deviceID: 2, timestamp: 0.2, contacts: []),
            while: false
        ))
        XCTAssertFalse(gate.shouldSuppress(occupiedDeviceTwo, while: false))
        XCTAssertFalse(gate.shouldSuppress(occupiedDeviceOne, while: false))
    }
}
