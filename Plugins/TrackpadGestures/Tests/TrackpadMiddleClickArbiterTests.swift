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

private final class LockedTipTapCommitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [TrackpadTipTapEpisodeID] = []

    var values: [TrackpadTipTapEpisodeID] {
        lock.withLock { storedValues }
    }

    func append(_ episodeID: TrackpadTipTapEpisodeID) {
        lock.withLock { storedValues.append(episodeID) }
    }
}

final class TrackpadMiddleClickArbiterTests: XCTestCase {

    func testBufferedCandidateDragReplaysNativeInputAndStopsGestureOwnership() {
        var arbiter = makeArbiter()
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left), origin: .trackpad(deviceID: 1), at: 0.01
            ).decision,
            .suppressAndBuffer
        )

        let drag = arbiter.handleNativeEvent(
            .drag(.left), origin: .trackpad(deviceID: 1), at: 0.011
        )

        XCTAssertEqual(drag.decision, .replayBufferedThenCurrent)
        XCTAssertEqual(drag.deferredActions, [.replayBuffered])
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.left), origin: .trackpad(deviceID: 1), at: 0.02
            ).decision,
            .passThrough
        )
        XCTAssertEqual(
            arbiter.attemptRecognition(
                deviceID: 1,
                resolution: .consume,
                at: 0.03
            ).disposition,
            .rejected
        )
    }

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

    func testDoubleTapBuffersTwoNativePairsAndEmitsOneMiddleClick() {
        var arbiter = makeArbiter()
        let first = TrackpadContactEpisodeID(deviceID: 1, sequence: 1)
        let second = TrackpadContactEpisodeID(deviceID: 1, sequence: 2)
        arbiter.observeCandidate(deviceID: 1, contactEpisodeID: first, at: 0)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left),
                origin: .trackpad(deviceID: 1),
                at: 0.01,
                contactEpisodeID: first,
                pairCapacity: 2
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.left),
                origin: .trackpad(deviceID: 1),
                at: 0.02,
                contactEpisodeID: first,
                pairCapacity: 2
            ).decision,
            .suppressAndBuffer
        )
        arbiter.observeCandidate(deviceID: 1, contactEpisodeID: second, at: 0.10)
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .down(.left),
                origin: .trackpad(deviceID: 1),
                at: 0.11,
                contactEpisodeID: second,
                pairCapacity: 2
            ).decision,
            .suppressAndBuffer
        )
        XCTAssertEqual(
            arbiter.handleNativeEvent(
                .up(.left),
                origin: .trackpad(deviceID: 1),
                at: 0.12,
                contactEpisodeID: second,
                pairCapacity: 2
            ).decision,
            .suppressAndBuffer
        )

        let attempt = arbiter.attemptRecognition(
            deviceID: 1,
            contactEpisodeID: second,
            resolution: .middleClick,
            requiredNativeClickPairCount: 2,
            at: 0.13
        )

        XCTAssertEqual(attempt.disposition, .committed)
        XCTAssertEqual(attempt.deferredActions, [.discardBuffered, .synthesizeMiddleClick])
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

    func testTipTapRecognitionBeforeNativeCommitsOnlyAfterExactSafePair() throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            commitTipTapRecognition: { commits.append($0) },
            allowsContactInference: { true },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .consume])
        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 2, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.15
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.15, contacts: fixed))

        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertTrue(commits.values.isEmpty)

        clock.value = 0.151
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 101))
        ))
        XCTAssertEqual(
            coordinator.nativeClickOwnershipEpisodeIDForTests(
                button: .left,
                eventNumber: 101
            )?.sequence,
            1
        )
        XCTAssertEqual(commits.values.count, 1)
        clock.value = 0.152
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 101))
        ))
        XCTAssertEqual(commits.values.count, 1)
        coordinator.reset()
    }

    func testCoordinatorReplaysBufferedNativeClickWhenTipTapEpisodeFails() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .consume])
        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        clock.value = 0.11
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.112
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))

        clock.value = 0.12
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.12,
            contacts: fixed + [.init(identifier: 2, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.16
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        clock.value = 0.45
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.45, contacts: fixed))

        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
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

    func testMiddleClickConversionRewritesDragWithMatchingButton() throws {
        let clock = LockedMiddleClickTestClock()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.threeFingerTap: .middleClick])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(coordinator.recognize(
            gesture: .threeFingerTap,
            deviceID: 1,
            resolution: .middleClick
        ))

        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 102))
        let drag = try XCTUnwrap(makeMouseEvent(type: .leftMouseDragged, eventNumber: 102))
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 102))
        clock.value = 0.02
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.03
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDragged, event: drag))
        clock.value = 0.04
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))

        XCTAssertEqual(down.type, .otherMouseDown)
        XCTAssertEqual(drag.type, .otherMouseDragged)
        XCTAssertEqual(up.type, .otherMouseUp)
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

    func testConfigurationInvalidationFinishesConsumedAndConvertedNativePairs() {
        for resolution in [TrackpadNativeClickResolution.consume, .middleClick] {
            var arbiter = TrackpadMiddleClickArbiter()
            _ = arbiter.observeCandidate(deviceID: 1, at: 0)
            XCTAssertTrue(arbiter.attemptRecognition(
                deviceID: 1,
                resolution: resolution,
                at: 0.01
            ).wasAccepted)

            let down = arbiter.handleNativeEvent(
                .down(.left),
                origin: .trackpad(deviceID: 1),
                at: 0.02
            )
            XCTAssertEqual(
                down.decision,
                resolution == .consume ? .suppress : .rewriteAsMiddle
            )
            XCTAssertTrue(
                arbiter.invalidatePendingRecognitionsForConfigurationChange().isEmpty
            )

            let up = arbiter.handleNativeEvent(
                .up(.left),
                origin: .trackpad(deviceID: 1),
                at: 0.03
            )
            XCTAssertEqual(
                up.decision,
                resolution == .consume ? .suppress : .rewriteAsMiddle
            )
        }
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

    private func makeMouseEvent(type: CGEventType, eventNumber: Int64 = 0) -> CGEvent? {
        let button: CGMouseButton = switch type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: .right
        default: .left
        }
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: button
        )
        event?.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        return event
    }
}

/// Uses the raw callback's notification cadence and the real recognition engine, while letting
/// tests control when worker recognition and native events reach the main-thread coordinator.
