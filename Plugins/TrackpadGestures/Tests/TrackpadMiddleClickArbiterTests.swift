import CoreGraphics
import MacToolsPluginKit
import XCTest
@testable import TrackpadGesturesPlugin

private final class LockedMiddleClickTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedPhysicalClickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [(TrackpadGesture, UInt64)] = []

    var values: [(TrackpadGesture, UInt64)] {
        lock.withLock { storedValues }
    }

    func append(_ gesture: TrackpadGesture, deviceID: UInt64) {
        lock.withLock { storedValues.append((gesture, deviceID)) }
    }
}

final class TrackpadMiddleClickArbiterTests: XCTestCase {
    func testShortcutRecognitionDiscardsCompleteBufferedNativeClick() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.left), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .suppressAndBuffer
        )

        XCTAssertEqual(
            arbiter.recognize(deviceID: 1, resolution: .consume, at: 0.03),
            [.discardBuffered]
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testShortcutRecognitionBeforeNativeClickSuppressesMatchingDownAndUp() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertTrue(arbiter.recognize(
            deviceID: 1,
            resolution: .consume,
            at: 0.01
        ).isEmpty)

        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.right), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .suppress
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.right), origin: .trackpad(deviceID: 1), at: 0.03
            ).decision,
            .suppress
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testShortcutRecognitionWithoutNativeClickDoesNotSynthesizeAnything() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        _ = arbiter.recognize(deviceID: 1, resolution: .consume, at: 0.01)

        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testResetAfterConsumedDownDoesNotPostBalancingMouseEvent() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        _ = arbiter.recognize(deviceID: 1, resolution: .consume, at: 0.01)
        _ = arbiter.handleNativeEvent(
            .down(.left), origin: .trackpad(deviceID: 1), at: 0.02
        )

        XCTAssertTrue(arbiter.reset().isEmpty)
    }
    func testRecognitionBeforeNativeClickRewritesDownAndMatchingUp() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)

        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.01).isEmpty)
        XCTAssertEqual(
            arbiter.handleNativeEvent(.down(.left), origin: .trackpad(deviceID: 1), at: 0.02),
            .init(decision: .rewriteAsMiddle, deferredActions: [])
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(.up(.left), origin: .trackpad(deviceID: 1), at: 0.03),
            .init(decision: .rewriteAsMiddle, deferredActions: [])
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testNativeClickBeforeRecognitionIsBufferedThenConvertedInOrder() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)

        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.right), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.right), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(
            arbiter.recognize(deviceID: 1, at: 0.03),
            [.convertBuffered]
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testBufferedNativeClickReplaysUnchangedWhenGestureDoesNotRecognize() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.left), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .suppressAndBuffer
        )

        XCTAssertEqual(arbiter.expire(at: 0.31), [.replayBuffered])
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testRecognitionAfterBufferedClickTimeoutDoesNotAddSyntheticClick() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )
        // Continued contact can outlast the bounded native-event buffer for a long-touch mapping.
        arbiter.observeCandidate(deviceID: 1, at: 0.29)
        XCTAssertEqual(arbiter.expire(at: 0.32), [.replayBuffered])

        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.33).isEmpty)
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testRecognitionSynthesizesOnlyAfterCandidateAmbiguityWindowExpires() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.01).isEmpty)

        XCTAssertTrue(arbiter.expire(at: 0.29).isEmpty)
        XCTAssertEqual(arbiter.expire(at: 0.31), [.synthesizeMiddleClick])
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testSeparateRecognitionWindowsEachSynthesizeOneMiddleClick() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.01).isEmpty)
        XCTAssertEqual(arbiter.expire(at: 0.31), [.synthesizeMiddleClick])

        arbiter.observeCandidate(deviceID: 1, at: 0.40)
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.41).isEmpty)
        XCTAssertEqual(arbiter.expire(at: 0.71), [.synthesizeMiddleClick])
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testLateUnknownNativeClickCancelsPendingSynthesis() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.03).isEmpty)

        XCTAssertTrue(arbiter.expire(at: 0.11).isEmpty)
        XCTAssertEqual(
            arbiter.handleNativeEvent(.down(.left), origin: .unknown, at: 0.12),
            .init(decision: .passThrough, deferredActions: [])
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(.up(.left), origin: .unknown, at: 0.13),
            .init(decision: .passThrough, deferredActions: [])
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testMultipleCandidateDevicesFailWithoutSuppressingOrSynthesizing() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        arbiter.observeCandidate(deviceID: 2, at: 0.01)

        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.02).isEmpty)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.03
            ).decision,
            .passThrough
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testRecognitionFromDifferentDeviceReplaysBufferedNativeClickWithoutMiddleClick() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )
        arbiter.observeCandidate(deviceID: 2, at: 0.02)

        XCTAssertEqual(
            arbiter.recognize(deviceID: 2, at: 0.03),
            [.replayBuffered]
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testNativeUpWithoutCorrelatedDownCancelsPendingSynthesis() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.01).isEmpty)

        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.left), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .passThrough
        )
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testResetAfterRecognitionBeforeNativeDownBalancesConvertedButton() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.01).isEmpty)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .rewriteAsMiddle
        )

        XCTAssertEqual(arbiter.reset(), [.releaseConvertedMiddleButton])
        XCTAssertTrue(arbiter.reset().isEmpty)
    }

    func testResetAfterBufferedDownConversionBalancesConvertedButton() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.right), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(arbiter.recognize(deviceID: 1, at: 0.02), [.convertBuffered])

        XCTAssertEqual(arbiter.reset(), [.releaseConvertedMiddleButton])
    }

    func testConvertedDownIsBalancedWhenNativeUpNeverArrives() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        _ = arbiter.recognize(deviceID: 1, at: 0.01)
        _ = arbiter.handleNativeEvent(
            .down(.left), origin: .trackpad(deviceID: 1), at: 0.02
        )

        XCTAssertEqual(arbiter.expire(at: 0.23), [.releaseConvertedMiddleButton])
    }

    func testExternalMouseClickPassesThroughAndCancelsOverlappingSynthesis() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)

        XCTAssertEqual(
            arbiter.handleNativeEvent(.down(.left), origin: .external, at: 0.01).decision,
            .passThrough
        )
        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.02).isEmpty)
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testUnknownNativeClickBeforeCandidateDeliveryMakesLaterCandidateAmbiguous() {
        var arbiter = makeArbiter()
        XCTAssertEqual(
            arbiter.handleNativeEvent(.down(.left), origin: .unknown, at: 0.01).decision,
            .passThrough
        )
        arbiter.observeCandidate(deviceID: 1, at: 0.02)

        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.03).isEmpty)
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testCorrelatedOriginBeforeCandidateDeliveryStillFailsWithoutDuplicateSynthesis() {
        var arbiter = makeArbiter()
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .passThrough
        )
        arbiter.observeCandidate(deviceID: 1, at: 0.02)

        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.03).isEmpty)
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    func testEpisodeAmbiguitySurvivesUntilLongTouchRecognition() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(.down(.left), origin: .unknown, at: 0.01).decision,
            .passThrough
        )
        arbiter.observeCandidate(deviceID: 1, at: 0.55, isAmbiguous: true)

        XCTAssertTrue(arbiter.recognize(deviceID: 1, at: 0.56).isEmpty)
        XCTAssertTrue(arbiter.expire(at: 1).isEmpty)
    }

    private func makeArbiter() -> TrackpadMiddleClickArbiter {
        TrackpadMiddleClickArbiter(
            candidateWindow: 0.30,
            postRecognitionWindow: 0.05,
            convertedReleaseWindow: 0.20
        )
    }
}

@MainActor
final class TrackpadMiddleClickCoordinatorTests: XCTestCase {
    func testCandidateTimelineRetainsTipTapSuppressionThroughTerminalZeroFrame() {
        let timeline = TrackpadMiddleClickCandidateTimeline()
        timeline.update(gestures: [.twoFingerClick, .tipTapMiddleTwoFixed])
        let fixedContacts = makeTwoContactFrame().contacts
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0, contacts: []),
            at: 0
        )
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0, contacts: fixedContacts),
            at: 0
        )
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixedContacts),
            at: 0.10
        )
        timeline.observe(
            frame: .init(
                deviceID: 1,
                timestamp: 0.11,
                contacts: fixedContacts + [.init(identifier: 3, x: 0.5, y: 0.5)]
            ),
            at: 0.11
        )
        XCTAssertTrue(timeline.suppressesPhysicalClick(deviceID: 1))

        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.12, contacts: []),
            at: 0.12
        )
        XCTAssertTrue(timeline.suppressesPhysicalClick(deviceID: 1))

        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.13, contacts: fixedContacts),
            at: 0.13
        )
        XCTAssertFalse(timeline.suppressesPhysicalClick(deviceID: 1))
    }

    func testCoordinatorConsumesTwoFingerPhysicalClickAndRecognizesItOnce() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.twoFingerClick: .consume])
        coordinator.observe(frame: makeTwoContactFrame())

        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .rightMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .rightMouseDown, event: down))
        clock.value = 0.02
        let up = try XCTUnwrap(makeMouseEvent(type: .rightMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(type: .rightMouseUp, event: up))

        XCTAssertEqual(recognized.values.map(\.0), [.twoFingerClick])
        XCTAssertEqual(recognized.values.map(\.1), [1])
        coordinator.reset()
    }

    func testCoordinatorDoesNotClaimTwoFingerClickAfterTwoFixedFingerTipTap() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .twoFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: fixedContacts
        ))
        clock.value = 0.10
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.10,
            contacts: fixedContacts + [
                .init(identifier: 3, x: 0.5, y: 0.5),
            ]
        ))
        clock.value = 0.15
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.15,
            contacts: fixedContacts
        ))

        clock.value = 0.16
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        _ = coordinator.handleNativeEvent(type: .leftMouseDown, event: down)

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorDoesNotClaimThreeFingerClickAtTwoFixedFingerTipTapPeak() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .threeFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: []
        ))
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: fixedContacts
        ))
        clock.value = 0.10
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.10,
            contacts: fixedContacts + [
                .init(identifier: 3, x: 0.5, y: 0.5),
            ]
        ))

        clock.value = 0.11
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        _ = coordinator.handleNativeEvent(type: .leftMouseDown, event: down)

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorLetsAddedContactFrameWinWhenNativeClickArrivesFirst() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            tipTapOrderingWindow: 0.02,
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .twoFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: fixedContacts))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixedContacts))

        clock.value = 0.11
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        XCTAssertTrue(recognized.values.isEmpty)

        clock.value = 0.115
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.115,
            contacts: fixedContacts + [.init(identifier: 3, x: 0.5, y: 0.5)]
        ))
        clock.value = 0.14
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.14,
            contacts: fixedContacts + [.init(identifier: 3, x: 0.5, y: 0.5)]
        ))

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorDelaysOnlyArmedTipTapOverlappingPhysicalClick() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            tipTapOrderingWindow: 0.02,
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .twoFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: fixedContacts))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixedContacts))

        clock.value = 0.11
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        XCTAssertTrue(recognized.values.isEmpty)

        clock.value = 0.131
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.131, contacts: fixedContacts))

        XCTAssertEqual(recognized.values.map(\.0), [.twoFingerClick])
        coordinator.reset()
    }

    func testCoordinatorRejectsDeferredPhysicalClickWhenAnotherDeviceBecomesCandidate() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            tipTapOrderingWindow: 0.02,
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .twoFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 2, timestamp: 0, contacts: []))
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: fixedContacts))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixedContacts))

        clock.value = 0.11
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))

        clock.value = 0.12
        coordinator.observe(frame: .init(deviceID: 2, timestamp: 0.12, contacts: fixedContacts))
        clock.value = 0.14
        coordinator.observe(frame: .init(deviceID: 2, timestamp: 0.14, contacts: fixedContacts))

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorDoesNotDeliverDeferredActionAfterSecondNativeDownIsRejected() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            tipTapOrderingWindow: 0.02,
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .twoFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: fixedContacts))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixedContacts))

        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        clock.value = 0.11
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.115
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))

        clock.value = 0.14
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.14, contacts: fixedContacts))

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorRecognizesCleanPhysicalClickAfterTipTapEpisodeEnds() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .threeFingerClick: .consume,
            .tipTapMiddleTwoFixed: .consume,
        ])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        let fixedContacts = makeTwoContactFrame().contacts
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: fixedContacts))
        clock.value = 0.10
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: fixedContacts + [.init(identifier: 3, x: 0.5, y: 0.5)]
        ))
        clock.value = 0.15
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.15, contacts: []))

        clock.value = 0.20
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.20,
            contacts: [
                .init(identifier: 4, x: 0.2, y: 0.5),
                .init(identifier: 5, x: 0.5, y: 0.5),
                .init(identifier: 6, x: 0.8, y: 0.5),
            ]
        ))
        clock.value = 0.21
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        _ = coordinator.handleNativeEvent(type: .leftMouseDown, event: down)

        XCTAssertEqual(recognized.values.map(\.0), [.threeFingerClick])
        coordinator.reset()
    }

    func testCoordinatorDoesNotClaimExternalClickDuringPhysicalClickCandidate() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .external }
        )
        coordinator.updateClickResolutions([.threeFingerClick: .consume])
        coordinator.observe(frame: makeThreeContactFrame())

        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorDoesNotRecognizePhysicalClickAfterContactsLift() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.twoFingerClick: .consume])
        coordinator.observe(frame: makeTwoContactFrame())
        clock.value = 0.01
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.01,
            contacts: []
        ))

        clock.value = 0.02
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        _ = coordinator.handleNativeEvent(type: .leftMouseDown, event: down)

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorInfersSingleUnknownTipTapCandidateAndConsumesShortcutClick() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .consume])
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [
                .init(identifier: 1, x: 0.5, y: 0.5),
                .init(identifier: 2, x: 0.1, y: 0.5),
            ]
        ))
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))

        clock.value = 0.01
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.02
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))
        clock.value = 0.03
        coordinator.recognize(deviceID: 1, resolution: .consume)

        XCTAssertTrue(postedTypes.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorDoesNotInferUnknownOriginWithTwoActiveCandidates() throws {
        let clock = LockedMiddleClickTestClock()
        let coordinator = TrackpadMiddleClickCoordinator(clock: { clock.value })
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .consume])
        let contacts = [
            TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5),
        ]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: contacts))
        coordinator.observe(frame: .init(deviceID: 2, timestamp: 0, contacts: contacts))
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))

        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        coordinator.reset()
    }
    func testCoordinatorConvertsBufferedNativeClickWithoutSyntheticDuplicate() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        var releasedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: { releasedCount += 1 },
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [
                .init(identifier: 1, x: 0.2, y: 0.5),
                .init(identifier: 2, x: 0.5, y: 0.5),
                .init(identifier: 3, x: 0.8, y: 0.5),
            ]
        ))
        let location = CGPoint(x: 100, y: 100)
        let down = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        ))
        let up = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ))

        clock.value = 0.01
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.02
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))
        clock.value = 0.03
        coordinator.recognize(deviceID: 1)

        XCTAssertEqual(postedTypes, [.otherMouseDown, .otherMouseUp])
        XCTAssertEqual(synthesizedCount, 0)
        XCTAssertEqual(releasedCount, 0)
        coordinator.reset()
    }

    func testCoordinatorResetPostsBalancingUpAfterRewrittenDown() throws {
        let clock = LockedMiddleClickTestClock()
        var releasedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: { releasedCount += 1 },
            postEvent: { _ in },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        coordinator.recognize(deviceID: 1)
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        clock.value = 0.02
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))

        coordinator.reset()

        XCTAssertEqual(releasedCount, 1)
    }

    func testCoordinatorResetPostsBalancingUpAfterBufferedDownConversion() throws {
        let clock = LockedMiddleClickTestClock()
        var releasedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: { releasedCount += 1 },
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.02
        coordinator.recognize(deviceID: 1)

        coordinator.reset()

        XCTAssertEqual(postedTypes, [.otherMouseDown])
        XCTAssertEqual(releasedCount, 1)
    }

    func testCandidateSynchronizationProcessesExpiredBufferedReplay() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))

        clock.value = 0.40
        coordinator.observe(frame: makeThreeContactFrame())

        XCTAssertEqual(postedTypes, [.leftMouseDown])
        coordinator.reset()
    }

    func testCoordinatorPreservesExternalMouseClickDuringTrackpadCandidate() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { _ in },
            eventOrigin: { _ in .external }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        clock.value = 0.01

        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.02
        coordinator.recognize(deviceID: 1)
        clock.value = 1
        coordinator.reset()

        XCTAssertEqual(synthesizedCount, 0)
    }

    func testCoordinatorInfersUnknownClickDuringSingleLongTouchEpisode() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { _ in }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.30
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.55
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.56
        coordinator.recognize(deviceID: 1)
        clock.value = 0.70
        coordinator.observe(frame: makeThreeContactFrame())

        XCTAssertEqual(synthesizedCount, 0)
        coordinator.reset()
    }

    func testCoordinatorClearsInferredCandidateWhenContactEpisodeEnds() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { _ in }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.02
        coordinator.observe(frame: TrackpadContactFrame(deviceID: 1, timestamp: 0.02, contacts: []))
        clock.value = 0.60
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.61
        coordinator.recognize(deviceID: 1)
        clock.value = 0.95
        coordinator.observe(frame: makeThreeContactFrame())

        XCTAssertEqual(synthesizedCount, 1)
        coordinator.reset()
    }

    func testCoordinatorRetainsReleasedTapCandidateUntilRecognitionDelivery() {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { _ in }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.02
        coordinator.observe(frame: TrackpadContactFrame(deviceID: 1, timestamp: 0.02, contacts: []))
        clock.value = 0.03
        coordinator.recognize(deviceID: 1)
        clock.value = 0.34
        coordinator.observe(frame: TrackpadContactFrame(deviceID: 1, timestamp: 0.34, contacts: []))

        XCTAssertEqual(synthesizedCount, 1)
        coordinator.reset()
    }

    func testCoordinatorCancelsFallbackForLateUnknownNativeClick() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { _ in }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.03
        coordinator.recognize(deviceID: 1)

        clock.value = 0.12
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.40
        coordinator.observe(frame: TrackpadContactFrame(deviceID: 1, timestamp: 0.40, contacts: []))

        XCTAssertEqual(synthesizedCount, 0)
        coordinator.reset()
    }

    private func makeThreeContactFrame() -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [
                .init(identifier: 1, x: 0.2, y: 0.5),
                .init(identifier: 2, x: 0.5, y: 0.5),
                .init(identifier: 3, x: 0.8, y: 0.5),
            ]
        )
    }

    private func makeTwoContactFrame() -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [
                .init(identifier: 1, x: 0.3, y: 0.5),
                .init(identifier: 2, x: 0.7, y: 0.5),
            ]
        )
    }

    private func makeMouseEvent(type: CGEventType) -> CGEvent? {
        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        )
    }
}
