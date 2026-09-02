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

    func testStaleContactEpisodeCannotClaimNewerCandidate() {
        var arbiter = makeArbiter()
        let first = TrackpadContactEpisodeID(deviceID: 1, sequence: 1)
        let second = TrackpadContactEpisodeID(deviceID: 1, sequence: 2)
        arbiter.observeCandidate(deviceID: 1, contactEpisodeID: first, at: 0)
        arbiter.observeCandidate(deviceID: 1, contactEpisodeID: second, at: 0.10)

        let attempt = arbiter.attemptRecognition(
            deviceID: 1,
            contactEpisodeID: first,
            at: 0.11
        )

        XCTAssertEqual(attempt.disposition, .rejected)
        XCTAssertTrue(attempt.deferredActions.isEmpty)
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

    func testUnrecognizedDoubleTapReplaysFirstNativePair() {
        var arbiter = makeArbiter()
        let episode = TrackpadContactEpisodeID(deviceID: 1, sequence: 1)
        arbiter.observeCandidate(deviceID: 1, contactEpisodeID: episode, at: 0)
        _ = arbiter.handleNativeEvent(
            .down(.left),
            origin: .trackpad(deviceID: 1),
            at: 0.01,
            contactEpisodeID: episode,
            pairCapacity: 2
        )
        _ = arbiter.handleNativeEvent(
            .up(.left),
            origin: .trackpad(deviceID: 1),
            at: 0.02,
            contactEpisodeID: episode,
            pairCapacity: 2
        )

        XCTAssertEqual(arbiter.expire(at: 0.34), [.replayBuffered])
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

    func testTipTapRecognitionExpirationReportsExactAbandonedEpisode() {
        var arbiter = makeArbiter()
        let episodeID = TrackpadTipTapEpisodeID(
            deviceID: 1,
            fixedFingerCount: 1,
            sequence: 7
        )
        arbiter.observeCandidate(deviceID: 1, at: 0)
        let attempt = arbiter.attemptRecognition(
            deviceID: 1,
            tipTapEpisodeID: episodeID,
            resolution: .consume,
            at: 0.01
        )
        XCTAssertEqual(attempt.disposition, .pending)

        XCTAssertEqual(arbiter.expire(at: 0.33), [
            .abandonTipTapRecognition(episodeID),
        ])
    }

    func testResetReportsEveryAbandonedTipTapEpisodeInFIFOOrder() {
        var arbiter = makeArbiter()
        let first = TrackpadTipTapEpisodeID(deviceID: 1, fixedFingerCount: 1, sequence: 1)
        let second = TrackpadTipTapEpisodeID(deviceID: 1, fixedFingerCount: 1, sequence: 2)
        arbiter.observeCandidate(deviceID: 1, at: 0)
        XCTAssertEqual(arbiter.attemptRecognition(
            deviceID: 1,
            tipTapEpisodeID: first,
            resolution: .consume,
            at: 0.01
        ).disposition, .pending)
        XCTAssertEqual(arbiter.attemptRecognition(
            deviceID: 1,
            tipTapEpisodeID: second,
            resolution: .consume,
            at: 0.02
        ).disposition, .pending)

        XCTAssertEqual(arbiter.reset(), [
            .abandonTipTapRecognition(first),
            .abandonTipTapRecognition(second),
        ])
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
final class TrackpadNativeClickSourceInventoryTests: XCTestCase {
    func testMouseServiceMetadataFailsClosedUnlessUsagePairsAreComplete() {
        let missing = TrackpadNativeClickSourceInventory.HIDUsageMetadata(
            primaryUsagePage: nil,
            primaryUsage: nil,
            usagePairs: .missing
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.mouseServiceRelevance(for: missing),
            .indeterminate
        )

        let compositeUnknown = TrackpadNativeClickSourceInventory.HIDUsageMetadata(
            primaryUsagePage: 1,
            primaryUsage: 6,
            usagePairs: .missing
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.mouseServiceRelevance(for: compositeUnknown),
            .indeterminate
        )

        let keyboard = TrackpadNativeClickSourceInventory.HIDUsageMetadata(
            primaryUsagePage: 1,
            primaryUsage: 6,
            usagePairs: .valid([.init(page: 1, usage: 6)])
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.mouseServiceRelevance(for: keyboard),
            .irrelevant
        )

        let compositeMouse = TrackpadNativeClickSourceInventory.HIDUsageMetadata(
            primaryUsagePage: 1,
            primaryUsage: 6,
            usagePairs: .valid([
                .init(page: 1, usage: 6),
                .init(page: 1, usage: 2),
            ])
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.mouseServiceRelevance(for: compositeMouse),
            .relevant
        )

        for pointingDevice in [
            TrackpadNativeClickSourceInventory.HIDUsageMetadata(
                primaryUsagePage: 1,
                primaryUsage: 1,
                usagePairs: .valid([.init(page: 1, usage: 1)])
            ),
            TrackpadNativeClickSourceInventory.HIDUsageMetadata(
                primaryUsagePage: 0x0D,
                primaryUsage: 0x02,
                usagePairs: .valid([.init(page: 0x0D, usage: 0x02)])
            ),
        ] {
            XCTAssertEqual(
                TrackpadNativeClickSourceInventory.mouseServiceRelevance(for: pointingDevice),
                .relevant
            )
        }

        let malformed = TrackpadNativeClickSourceInventory.HIDUsageMetadata(
            primaryUsagePage: nil,
            primaryUsage: nil,
            usagePairs: .malformed
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.mouseServiceRelevance(for: malformed),
            .indeterminate
        )

        let malformedCompositeWithMouse = TrackpadNativeClickSourceInventory.HIDUsageMetadata(
            primaryUsagePage: nil,
            primaryUsage: nil,
            usagePairs: .containsPointingDevice
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.mouseServiceRelevance(
                for: malformedCompositeWithMouse
            ),
            .relevant
        )
    }

    func testRelevantOrIndeterminateServiceEntryFailureMakesInventoryIncomplete() {
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.enumerationResult(
                relevance: .relevant,
                entry: nil
            ),
            .incomplete
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.enumerationResult(
                relevance: .indeterminate,
                entry: nil
            ),
            .incomplete
        )
        XCTAssertEqual(
            TrackpadNativeClickSourceInventory.enumerationResult(
                relevance: .irrelevant,
                entry: nil
            ),
            .complete([])
        )
    }

    func testOnlyMouseCapableServicesRelatedToTrackpadsAllowContactInference() {
        let builtInTrackpad = TrackpadNativeClickRegistryEntry(
            registryID: 10,
            ancestorRegistryIDs: [1]
        )
        let externalMagicTrackpad = TrackpadNativeClickRegistryEntry(
            registryID: 20,
            ancestorRegistryIDs: [2]
        )
        let builtInMouseService = TrackpadNativeClickRegistryEntry(
            registryID: 11,
            ancestorRegistryIDs: [10, 1]
        )
        let magicTrackpadMouseService = TrackpadNativeClickRegistryEntry(
            registryID: 21,
            ancestorRegistryIDs: [20, 2]
        )

        XCTAssertTrue(TrackpadNativeClickSourceInventorySnapshot(
            mouseEntries: [builtInMouseService, magicTrackpadMouseService],
            trackpadEntries: [builtInTrackpad, externalMagicTrackpad]
        ).allowsContactInference)
    }

    func testUnrelatedMouseOrIncompleteInventoryFailsOpen() {
        let trackpad = TrackpadNativeClickRegistryEntry(
            registryID: 10,
            ancestorRegistryIDs: [1]
        )
        let externalMouse = TrackpadNativeClickRegistryEntry(
            registryID: 30,
            ancestorRegistryIDs: [3]
        )

        XCTAssertFalse(TrackpadNativeClickSourceInventorySnapshot(
            mouseEntries: [externalMouse],
            trackpadEntries: [trackpad]
        ).allowsContactInference)
        XCTAssertFalse(TrackpadNativeClickSourceInventorySnapshot(
            mouseEntries: [],
            trackpadEntries: [trackpad]
        ).allowsContactInference)
        XCTAssertFalse(TrackpadNativeClickSourceInventorySnapshot(
            mouseEntries: [externalMouse],
            trackpadEntries: []
        ).allowsContactInference)
    }

    func testProductionClassifierRequiresHardwareSourceAndSafeInventory() throws {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertEqual(
            TrackpadNativeEventOriginClassifier.origin(
                for: event,
                allowsContactInference: { true }
            ),
            .contactInferenceAllowed
        )
        XCTAssertEqual(
            TrackpadNativeEventOriginClassifier.origin(
                for: event,
                allowsContactInference: { false }
            ),
            .unknown
        )

        event.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
        XCTAssertEqual(
            TrackpadNativeEventOriginClassifier.origin(
                for: event,
                allowsContactInference: { true }
            ),
            .external
        )
    }
}

@MainActor
final class TrackpadMiddleClickCoordinatorTests: XCTestCase {
    func testMixedFixedCountTipTapsUseDistinctEpisodeIDsAcrossRepeatedTwoFixedTaps() throws {
        let timeline = TrackpadMiddleClickCandidateTimeline()
        timeline.update(gestures: [
            .tipTapLeftOneFixed,
            .tipTapRightOneFixed,
            .tipTapLeftTwoFixed,
            .tipTapMiddleTwoFixed,
            .tipTapRightTwoFixed,
        ])
        let firstFixed = TrackpadContactSnapshot(identifier: 1, x: 0.4, y: 0.5)
        let secondFixed = TrackpadContactSnapshot(identifier: 2, x: 0.6, y: 0.5)
        let fixed = [firstFixed, secondFixed]

        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0, contacts: []),
            at: 0
        )
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.01, contacts: [firstFixed]),
            at: 0.01
        )
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.10, contacts: [firstFixed]),
            at: 0.10
        )
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.11, contacts: fixed),
            at: 0.11
        )
        timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed),
            at: 0.20
        )
        timeline.observe(
            frame: .init(
                deviceID: 1,
                timestamp: 0.21,
                contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
            ),
            at: 0.21
        )
        XCTAssertEqual(
            timeline.takeNewTipTapEpisodeStarts().filter {
                $0.id.fixedFingerCount == 2
            }.count,
            1
        )
        let firstRelease = timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.25, contacts: fixed),
            at: 0.25
        )
        let firstEpisodeID = try XCTUnwrap(
            firstRelease.tipTapRecognitionIDs[.tipTapLeftTwoFixed]
        )
        XCTAssertEqual(firstEpisodeID.fixedFingerCount, 2)
        XCTAssertEqual(
            timeline.nativeCorrelationTipTapEpisodeID(deviceID: 1, at: 0.251),
            firstEpisodeID
        )

        timeline.observe(
            frame: .init(
                deviceID: 1,
                timestamp: 0.30,
                contacts: fixed + [.init(identifier: 4, x: 0.9, y: 0.5)]
            ),
            at: 0.30
        )
        let secondRelease = timeline.observe(
            frame: .init(deviceID: 1, timestamp: 0.34, contacts: fixed),
            at: 0.34
        )
        let secondEpisodeID = try XCTUnwrap(
            secondRelease.tipTapRecognitionIDs[.tipTapRightTwoFixed]
        )
        XCTAssertEqual(secondEpisodeID.fixedFingerCount, 2)
        XCTAssertNotEqual(secondEpisodeID, firstEpisodeID)
        XCTAssertGreaterThan(secondEpisodeID.sequence, firstEpisodeID.sequence)
        XCTAssertEqual(
            timeline.nativeCorrelationTipTapEpisodeID(deviceID: 1, at: 0.341),
            firstEpisodeID
        )
        timeline.completeTipTapRecognition(firstEpisodeID)
        XCTAssertEqual(
            timeline.nativeCorrelationTipTapEpisodeID(deviceID: 1, at: 0.342),
            secondEpisodeID
        )
    }

    func testMixedFixedCountTipTapsConsumePostReleaseNativeClicksForRepeatedTwoFixedTaps()
        throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
        coordinator.updateClickResolutions([
            .tipTapLeftOneFixed: .consume,
            .tipTapRightOneFixed: .consume,
            .tipTapLeftTwoFixed: .consume,
            .tipTapMiddleTwoFixed: .consume,
            .tipTapRightTwoFixed: .consume,
        ])
        let firstFixed = TrackpadContactSnapshot(identifier: 1, x: 0.4, y: 0.5)
        let fixed = [
            firstFixed,
            TrackpadContactSnapshot(identifier: 2, x: 0.6, y: 0.5),
        ]

        clock.value = 0
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        clock.value = 0.01
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: [firstFixed]
        ))
        clock.value = 0.10
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [firstFixed]
        ))
        clock.value = 0.11
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.11, contacts: fixed))
        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed))

        clock.value = 0.21
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.21,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.25
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.25, contacts: fixed))
        clock.value = 0.251
        let firstDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: firstDown))
        clock.value = 0.252
        let firstUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: firstUp))
        clock.value = 0.30
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftTwoFixed,
            deviceID: 1,
            resolution: .consume
        ))

        clock.value = 0.31
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.31,
            contacts: fixed + [.init(identifier: 4, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.35
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.35, contacts: fixed))
        clock.value = 0.351
        let secondDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: secondDown))
        clock.value = 0.352
        let secondUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: secondUp))
        clock.value = 0.40
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapRightTwoFixed,
            deviceID: 1,
            resolution: .consume
        ))

        XCTAssertEqual(synthesizedCount, 0)
        XCTAssertTrue(postedTypes.isEmpty)
        coordinator.reset()
    }

    func testDelayedOneFixedRecognitionCannotConsumeMixedTwoFixedEpisodeClick() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
        coordinator.updateClickResolutions([
            .tipTapLeftOneFixed: .consume,
            .tipTapRightOneFixed: .consume,
            .tipTapLeftTwoFixed: .consume,
            .tipTapMiddleTwoFixed: .consume,
            .tipTapRightTwoFixed: .consume,
        ])
        let firstFixed = TrackpadContactSnapshot(identifier: 1, x: 0.4, y: 0.5)

        clock.value = 0
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        clock.value = 0.01
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: [firstFixed]
        ))
        clock.value = 0.10
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [firstFixed]
        ))
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: [firstFixed, .init(identifier: 2, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.15
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.15,
            contacts: [firstFixed]
        ))
        clock.value = 0.16
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.16, contacts: []))

        let secondFixed = TrackpadContactSnapshot(identifier: 3, x: 0.6, y: 0.5)
        let fixed = [firstFixed, secondFixed]
        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed))
        clock.value = 0.29
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.29, contacts: fixed))
        clock.value = 0.30
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.30,
            contacts: fixed + [.init(identifier: 4, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.301
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.302
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))

        clock.value = 0.31
        XCTAssertFalse(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertTrue(postedTypes.isEmpty)

        clock.value = 0.34
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.34, contacts: fixed))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapRightTwoFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertTrue(postedTypes.isEmpty)
        coordinator.reset()
    }

    func testCandidateTimelineEndsSuppressionWhenFixedFingersLiftWithAddedContact() {
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
        XCTAssertFalse(timeline.suppressesPhysicalClick(deviceID: 1))

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

    func testCoordinatorInfersExplicitlyAllowedTipTapCandidateAndConsumesShortcutClick() throws {
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

    func testCoordinatorDefaultUnknownOriginUsesUniqueExactCandidate() throws {
        let clock = LockedMiddleClickTestClock()
        let coordinator = TrackpadMiddleClickCoordinator(clock: { clock.value })
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
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: down
        ))
        coordinator.reset()
    }

    func testInferredTrackpadDownKeepsOriginThroughMatchingUp() throws {
        let clock = LockedMiddleClickTestClock()
        var originCallCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            eventOrigin: { _ in
                defer { originCallCount += 1 }
                return originCallCount == 0 ? .contactInferenceAllowed : .unknown
            }
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

        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        coordinator.reset()
    }

    func testOverlappingSameButtonClicksUseEventNumberForStickyOrigins() throws {
        let clock = LockedMiddleClickTestClock()
        var releasedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            releaseMiddleButton: { releasedCount += 1 },
            eventOrigin: { event in
                event.getIntegerValueField(.mouseEventNumber) == 101
                    ? .trackpad(deviceID: 1)
                    : .external
            }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        XCTAssertTrue(coordinator.recognize(deviceID: 1))

        let trackpadDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 101
        ))
        let externalDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 202
        ))
        let trackpadUp = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseUp,
            eventNumber: 101
        ))
        let externalUp = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseUp,
            eventNumber: 202
        ))

        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: trackpadDown))
        XCTAssertEqual(trackpadDown.type, .otherMouseDown)
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: externalDown))
        XCTAssertEqual(externalDown.type, .leftMouseDown)
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: trackpadUp))
        XCTAssertEqual(trackpadUp.type, .otherMouseUp)
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: externalUp))
        XCTAssertEqual(externalUp.type, .leftMouseUp)

        coordinator.reset()
        XCTAssertEqual(releasedCount, 0)
    }

    func testDuplicateClickKeyFailsOpenAndBalancesConvertedDownOnce() throws {
        let clock = LockedMiddleClickTestClock()
        var releasedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            releaseMiddleButton: { releasedCount += 1 },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        XCTAssertTrue(coordinator.recognize(deviceID: 1))

        let firstDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 101
        ))
        let duplicateDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 101
        ))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: firstDown))
        XCTAssertEqual(firstDown.type, .otherMouseDown)
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: duplicateDown))
        XCTAssertEqual(duplicateDown.type, .leftMouseDown)
        XCTAssertEqual(releasedCount, 1)

        let firstUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 101))
        let secondUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 101))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: firstUp))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: secondUp))
        coordinator.reset()
        XCTAssertEqual(releasedCount, 1)
    }

    func testOverlappingSameButtonConsumeSuppressesOnlyOwningPair() throws {
        let clock = LockedMiddleClickTestClock()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            eventOrigin: { event in
                event.getIntegerValueField(.mouseEventNumber) == 101
                    ? .trackpad(deviceID: 1)
                    : .external
            }
        )
        coordinator.updateClickResolutions([.threeFingerTap: .consume])
        coordinator.observe(frame: makeThreeContactFrame())
        XCTAssertTrue(coordinator.recognize(deviceID: 1, resolution: .consume))

        let trackpadDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 101
        ))
        let externalDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 202
        ))
        let externalUp = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseUp,
            eventNumber: 202
        ))
        let trackpadUp = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseUp,
            eventNumber: 101
        ))

        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: trackpadDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: externalDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: externalUp))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: trackpadUp))
        coordinator.reset()
    }

    func testCoordinatorBuffersNativeClickFromFixedPhaseWhenOnlyTipTapIsConfigured() throws {
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

        let added = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        clock.value = 0.115
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.115,
            contacts: fixed + [added]
        ))
        clock.value = 0.16
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.16, contacts: fixed))

        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertTrue(postedTypes.isEmpty)
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

    func testUnsafeInventoryStillCorrelatesExactTipTapNativePair() throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            commitTipTapRecognition: { commits.append($0) },
            allowsContactInference: { false },
            eventOrigin: { _ in .unknown }
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
        XCTAssertEqual(commits.values.count, 1)
        clock.value = 0.152
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 101))
        ))
        XCTAssertEqual(commits.values.count, 1)
        coordinator.reset()
    }

    func testUnsafeInventoryStillCorrelatesUniquePhysicalClickEpisode() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            recognizePhysicalClick: { gesture, deviceID in
                recognized.append(gesture, deviceID: deviceID)
            },
            allowsContactInference: { false },
            eventOrigin: { _ in .unknown }
        )
        coordinator.updateClickResolutions([.twoFingerClick: .middleClick])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        clock.value = 0.01
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.01,
            contacts: [
                .init(identifier: 1, x: 0.4, y: 0.5),
                .init(identifier: 2, x: 0.6, y: 0.5),
            ]
        ))

        clock.value = 0.02
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 111))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        XCTAssertEqual(down.type, .otherMouseDown)
        XCTAssertEqual(recognized.values.count, 1)

        clock.value = 0.03
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 111))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))
        XCTAssertEqual(up.type, .otherMouseUp)
        coordinator.reset()
    }

    func testDoubleTapCoordinatorConsumesTwoPairsAndSynthesizesOnce() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            allowsContactInference: { false },
            eventOrigin: { _ in .unknown }
        )
        coordinator.updateClickResolutions([.threeFingerDoubleTap: .middleClick])
        let contacts = [
            TrackpadContactSnapshot(identifier: 1, x: 0.3, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.5, y: 0.5),
            TrackpadContactSnapshot(identifier: 3, x: 0.7, y: 0.5),
        ]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        clock.value = 0.01
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: contacts))
        clock.value = 0.02
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 121))
        ))
        clock.value = 0.03
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 121))
        ))
        clock.value = 0.04
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.04, contacts: []))

        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: contacts))
        clock.value = 0.21
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 122))
        ))
        clock.value = 0.22
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 122))
        ))
        clock.value = 0.23
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.23, contacts: []))

        XCTAssertTrue(coordinator.recognize(
            gesture: .threeFingerDoubleTap,
            deviceID: 1
        ))
        XCTAssertEqual(synthesizedCount, 1)
        coordinator.reset()
    }

    func testUnsafeInventoryDoesNotClaimProcessOwnedClickForTipTap() throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            commitTipTapRecognition: { commits.append($0) },
            allowsContactInference: { false },
            eventOrigin: { _ in .external }
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
        clock.value = 0.151
        let processOwnedDown = try XCTUnwrap(
            makeMouseEvent(type: .leftMouseDown, eventNumber: 102)
        )
        XCTAssertNotNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: processOwnedDown
        ))
        XCTAssertTrue(commits.values.isEmpty)
        coordinator.reset()
    }

    func testUnsafeInventoryDoesNotRejectExactOrdinaryTapEpisode() {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            allowsContactInference: { false }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.02
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.02,
            contacts: []
        ))
        clock.value = 0.03

        XCTAssertTrue(coordinator.recognize(
            gesture: .threeFingerTap,
            deviceID: 1
        ))

        clock.value = 0.34
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.34,
            contacts: []
        ))
        XCTAssertEqual(synthesizedCount, 1)
        coordinator.reset()
    }

    func testUnsafeInventoryDoesNotRejectExactOrdinaryLongTouchEpisode() {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            allowsContactInference: { false }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.30
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.55
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.56

        XCTAssertTrue(coordinator.recognize(
            gesture: .threeFingerLongTouch,
            deviceID: 1
        ))

        clock.value = 0.90
        coordinator.observe(frame: makeThreeContactFrame())
        XCTAssertEqual(synthesizedCount, 1)
        coordinator.reset()
    }

    func testLongTouchEvidenceDoesNotClaimUnknownNativeClick() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            allowsContactInference: { false },
            eventOrigin: { _ in .unknown }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())

        clock.value = 0.10
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 131))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        XCTAssertEqual(down.type, .leftMouseDown)
        clock.value = 0.11
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 131))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: up))
        XCTAssertEqual(up.type, .leftMouseUp)

        clock.value = 0.56
        XCTAssertFalse(coordinator.recognize(
            gesture: .threeFingerLongTouch,
            deviceID: 1
        ))
        XCTAssertEqual(synthesizedCount, 0)
        coordinator.reset()
    }

    func testOrdinaryTapMiddleClickCompletesWhenInventoryChangesAfterAdmission() {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            allowsContactInference: { clock.value < 0.30 }
        )
        coordinator.updateMiddleClickGestures([.threeFingerTap])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.02
        coordinator.observe(frame: TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0.02,
            contacts: []
        ))
        clock.value = 0.03
        XCTAssertTrue(coordinator.recognize(
            gesture: .threeFingerTap,
            deviceID: 1
        ))

        clock.value = 0.34
        coordinator.candidateTimelineDidUpdate()
        XCTAssertEqual(synthesizedCount, 1)
        clock.value = 1
        coordinator.candidateTimelineDidUpdate()
        XCTAssertEqual(synthesizedCount, 1)
        coordinator.reset()
    }

    func testOrdinaryLongTouchMiddleClickCompletesWhenInventoryChangesAfterAdmission() {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            allowsContactInference: { clock.value < 0.80 }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.30
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.55
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.56
        XCTAssertTrue(coordinator.recognize(
            gesture: .threeFingerLongTouch,
            deviceID: 1
        ))

        clock.value = 0.90
        coordinator.candidateTimelineDidUpdate()
        XCTAssertEqual(synthesizedCount, 1)
        clock.value = 1.20
        coordinator.candidateTimelineDidUpdate()
        XCTAssertEqual(synthesizedCount, 1)
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

    func testFixedFingerMovementImmediatelyReplaysBufferedTipTapPair() throws {
        try assertFixedFingerInstabilityImmediatelyReplaysBufferedTipTapPair(
            gesture: .tipTapLeftOneFixed,
            fixed: [.init(identifier: 1, x: 0.5, y: 0.5)],
            added: .init(identifier: 2, x: 0.1, y: 0.5),
            unstable: [
                .init(identifier: 1, x: 0.6, y: 0.5),
                .init(identifier: 2, x: 0.1, y: 0.5),
            ]
        )
    }

    func testFixedFingerRemovalImmediatelyReplaysBufferedTipTapPair() throws {
        let fixed = [
            TrackpadContactSnapshot(identifier: 1, x: 0.3, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.7, y: 0.5),
        ]
        let added = TrackpadContactSnapshot(identifier: 3, x: 0.5, y: 0.5)
        try assertFixedFingerInstabilityImmediatelyReplaysBufferedTipTapPair(
            gesture: .tipTapMiddleTwoFixed,
            fixed: fixed,
            added: added,
            unstable: [fixed[0], added]
        )
    }

    func testCoordinatorEndsPreviousRecognitionBeforeRejectedEpisodeClick() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .middleClick])
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
        clock.value = 0.16
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .middleClick
        ))
        XCTAssertEqual(synthesizedCount, 0)

        // A newer episode must not let the earlier recognition consume its click. While the
        // added contact is still down, preserve the pair until that newer episode resolves.
        clock.value = 0.18
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.18,
            contacts: fixed + [.init(identifier: 3, x: 0.9, y: 0.5)]
        ))
        XCTAssertEqual(synthesizedCount, 0)
        clock.value = 0.181
        XCTAssertTrue(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ) == nil)
        clock.value = 0.182
        XCTAssertTrue(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ) == nil)
        clock.value = 0.55
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.55, contacts: fixed))

        XCTAssertEqual(synthesizedCount, 0)
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        coordinator.reset()
    }

    func testCoordinatorCancelsDeferredPhysicalClickWhenTipTapFails() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .tipTapMiddleTwoFixed: .consume,
            .twoFingerClick: .consume,
        ])
        let fixed = [
            TrackpadContactSnapshot(identifier: 1, x: 0.4, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.6, y: 0.5),
        ]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.112
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))

        clock.value = 0.115
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.115,
            contacts: fixed + [.init(identifier: 3, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.16
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.16, contacts: fixed))

        XCTAssertTrue(recognized.values.isEmpty)
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        coordinator.reset()
    }

    func testCoordinatorReplaysConsecutiveFailedClicksBeforeRapidSuccessfulRetry() throws {
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

        let failedDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        let failedUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        clock.value = 0.11
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: failedDown))
        clock.value = 0.112
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: failedUp))
        clock.value = 0.12
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.12,
            contacts: fixed + [.init(identifier: 2, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.15
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.15, contacts: fixed))
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])

        let secondFailedDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        let secondFailedUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        clock.value = 0.17
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: secondFailedDown))
        clock.value = 0.172
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: secondFailedUp))
        clock.value = 0.18
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.18,
            contacts: fixed + [.init(identifier: 3, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed))
        XCTAssertEqual(postedTypes, [
            .leftMouseDown, .leftMouseUp,
            .leftMouseDown, .leftMouseUp,
        ])

        let validAdded = TrackpadContactSnapshot(identifier: 4, x: 0.1, y: 0.5)
        clock.value = 0.22
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.22,
            contacts: fixed + [validAdded]
        ))
        let validDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        let validUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        clock.value = 0.222
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: validDown))
        clock.value = 0.224
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: validUp))
        clock.value = 0.25
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.25, contacts: fixed))

        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertEqual(postedTypes, [
            .leftMouseDown, .leftMouseUp,
            .leftMouseDown, .leftMouseUp,
        ])
        coordinator.reset()
    }

    func testCoordinatorAllowsPhysicalClickAfterSuccessfulTipTapWithFixedFingersDown() throws {
        let clock = LockedMiddleClickTestClock()
        let recognized = LockedPhysicalClickRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            recognizePhysicalClick: { recognized.append($0, deviceID: $1) },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
        coordinator.updateClickResolutions([
            .tipTapMiddleTwoFixed: .consume,
            .twoFingerClick: .consume,
        ])
        let fixed = [
            TrackpadContactSnapshot(identifier: 1, x: 0.4, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.6, y: 0.5),
        ]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 3, x: 0.5, y: 0.5)]
        ))
        let tipTapDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        let tipTapUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        clock.value = 0.112
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: tipTapDown))
        clock.value = 0.114
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: tipTapUp))
        clock.value = 0.15
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.15, contacts: fixed))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapMiddleTwoFixed,
            deviceID: 1,
            resolution: .consume
        ))

        clock.value = 0.18
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        clock.value = 0.21
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.21, contacts: fixed))

        XCTAssertEqual(recognized.values.count, 1)
        XCTAssertEqual(recognized.values.first?.0, .twoFingerClick)
        XCTAssertEqual(recognized.values.first?.1, 1)
        coordinator.reset()
    }

    func testCoordinatorDefersPhysicalClickWhileTipTapSettlingFrameIsStale() throws {
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
        let fixed = makeTwoContactFrame().contacts
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: fixed))

        clock.value = 0.081
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
        XCTAssertTrue(recognized.values.isEmpty)

        clock.value = 0.085
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.085,
            contacts: fixed + [.init(identifier: 3, x: 0.5, y: 0.5)]
        ))
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 3, x: 0.5, y: 0.5)]
        ))

        XCTAssertTrue(recognized.values.isEmpty)
        coordinator.reset()
    }

    func testCoordinatorDoesNotInferUnknownOriginWithTwoActiveCandidates() throws {
        let clock = LockedMiddleClickTestClock()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
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

    func testCoordinatorDoesNotClaimNativeClickDuringSingleLongTouchEpisode() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { _ in },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
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
            postEvent: { _ in },
            eventOrigin: { _ in .contactInferenceAllowed }
        )
        coordinator.updateMiddleClickGestures([.threeFingerLongTouch])
        coordinator.observe(frame: makeThreeContactFrame())
        clock.value = 0.01
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: down))
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

    func testRejectedPostReleaseClickCannotBeConsumedByRapidValidRetry() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
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
            contacts: fixed + [.init(identifier: 2, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.12
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.12, contacts: fixed))

        clock.value = 0.121
        let rejectedDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNotNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: rejectedDown
        ))
        clock.value = 0.122
        let rejectedUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNotNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: rejectedUp
        ))

        clock.value = 0.13
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.13,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.131
        let validDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: validDown
        ))
        clock.value = 0.132
        let validUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: validUp
        ))
        clock.value = 0.18
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.18, contacts: fixed))

        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertTrue(postedTypes.isEmpty)
        coordinator.reset()
    }

    func testRejectedClickAfterOrderingWindowIsNotReboundToRapidValidRetry() throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
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
            contacts: fixed + [.init(identifier: 2, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.12
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.12, contacts: fixed))

        // The failed episode's native click arrives after the 20 ms frame-ordering window. It
        // remains owned by the rejected episode instead of becoming the retry's click.
        clock.value = 0.145
        let rejectedDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: rejectedDown
        ))
        clock.value = 0.147
        let rejectedUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: rejectedUp
        ))

        clock.value = 0.155
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.155,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        clock.value = 0.157
        let validDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseDown, event: validDown))
        clock.value = 0.159
        let validUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        XCTAssertNil(coordinator.handleNativeEvent(type: .leftMouseUp, event: validUp))
        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed))

        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(synthesizedCount, 0)
        coordinator.reset()
    }

    func testRejectedClickArrivingAfterRetryStartsIsReplayedBeforeConsumeRetry() throws {
        try assertRejectedClickArrivingAfterRetryStarts(
            resolution: .consume,
            expectedPostedTypes: [.leftMouseDown, .leftMouseUp]
        )
    }

    func testRejectedClickArrivingAfterRetryStartsIsReplayedBeforeMiddleClickRetry() throws {
        try assertRejectedClickArrivingAfterRetryStarts(
            resolution: .middleClick,
            expectedPostedTypes: [
                .leftMouseDown, .leftMouseUp,
                .otherMouseDown, .otherMouseUp,
            ]
        )
    }

    func testRejectedEpisodeWithoutNativePairDoesNotStealValidRetryPair() throws {
        try assertRejectedEpisodeWithoutNativePairDoesNotStealValidRetryPair(
            resolution: .consume,
            expectedPostedTypes: []
        )
    }

    func testRejectedEpisodeWithoutNativePairDoesNotStealMiddleClickRetryPair() throws {
        try assertRejectedEpisodeWithoutNativePairDoesNotStealValidRetryPair(
            resolution: .middleClick,
            expectedPostedTypes: [.otherMouseDown, .otherMouseUp]
        )
    }

    func testCompletedTipTapKeepsFIFOOwnershipAheadOfActiveAlternatingRetry() throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            commitTipTapRecognition: { commits.append($0) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([
            .tipTapLeftOneFixed: .consume,
            .tipTapRightOneFixed: .consume,
        ])
        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        let firstEpisodeID = TrackpadTipTapEpisodeID(
            deviceID: 1,
            fixedFingerCount: 1,
            sequence: 1
        )
        let secondEpisodeID = TrackpadTipTapEpisodeID(
            deviceID: 1,
            fixedFingerCount: 1,
            sequence: 2
        )

        // Successful A completes and waits for its native pair.
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
            tipTapEpisodeID: firstEpisodeID,
            resolution: .consume
        ))

        // Alternating retry B is active when A's delayed pair arrives. FIFO keeps the pair with A.
        clock.value = 0.16
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.16,
            contacts: fixed + [.init(identifier: 3, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.161
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 103))
        ))
        clock.value = 0.162
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 103))
        ))
        XCTAssertEqual(commits.values, [firstEpisodeID])

        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapRightOneFixed,
            deviceID: 1,
            tipTapEpisodeID: secondEpisodeID,
            resolution: .consume
        ))
        clock.value = 0.201
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 104))
        ))
        clock.value = 0.202
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 104))
        ))

        XCTAssertEqual(commits.values, [firstEpisodeID, secondEpisodeID])
        XCTAssertTrue(postedTypes.isEmpty)
        coordinator.reset()
    }

    func testDelayedRecognitionsConsumeOrderedTipTapEpisodeBuffers() throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        var synthesizedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            commitTipTapRecognition: { commits.append($0) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .middleClick])
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

        clock.value = 0.16
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.16,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.20
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.20, contacts: fixed))

        let firstEpisodeID = TrackpadTipTapEpisodeID(
            deviceID: 1,
            fixedFingerCount: 1,
            sequence: 1
        )
        let secondEpisodeID = TrackpadTipTapEpisodeID(
            deviceID: 1,
            fixedFingerCount: 1,
            sequence: 2
        )
        clock.value = 0.21
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            tipTapEpisodeID: firstEpisodeID,
            resolution: .middleClick
        ))
        XCTAssertEqual(synthesizedCount, 0)
        XCTAssertTrue(postedTypes.isEmpty)
        XCTAssertTrue(commits.values.isEmpty)

        clock.value = 0.22
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            tipTapEpisodeID: secondEpisodeID,
            resolution: .middleClick
        ))
        XCTAssertTrue(commits.values.isEmpty)

        let firstDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 101))
        clock.value = 0.23
        XCTAssertTrue(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: firstDown
        ) != nil)
        XCTAssertEqual(firstDown.type, .otherMouseDown)
        let firstUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 101))
        clock.value = 0.231
        XCTAssertTrue(coordinator.handleNativeEvent(type: .leftMouseUp, event: firstUp) != nil)
        XCTAssertEqual(firstUp.type, .otherMouseUp)
        XCTAssertEqual(commits.values, [firstEpisodeID])

        let secondDown = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 102))
        clock.value = 0.24
        XCTAssertTrue(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: secondDown
        ) != nil)
        XCTAssertEqual(secondDown.type, .otherMouseDown)
        let secondUp = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 102))
        clock.value = 0.241
        XCTAssertTrue(coordinator.handleNativeEvent(type: .leftMouseUp, event: secondUp) != nil)
        XCTAssertEqual(secondUp.type, .otherMouseUp)
        XCTAssertTrue(postedTypes.isEmpty)
        XCTAssertEqual(synthesizedCount, 0)
        XCTAssertEqual(commits.values, [firstEpisodeID, secondEpisodeID])
        coordinator.reset()
    }

    func testNativeClickAfterTipTapReleaseKeepsCompletedEpisodeIdentity() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
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

        clock.value = 0.151
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.152
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))

        XCTAssertTrue(postedTypes.isEmpty)
        coordinator.reset()
    }

    func testFixedOnlyTipTapBufferReplaysAfterOrderingWindow() throws {
        let clock = LockedMiddleClickTestClock()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            tipTapOrderingWindow: 0.02,
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: .consume])
        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        clock.value = 0.11
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.112
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        clock.value = 0.131
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.131, contacts: fixed))

        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        coordinator.reset()
    }

    func testPhysicalClickCanFollowRejectedTipTapWithoutLiftingFixedFingers() throws {
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
            .tipTapMiddleTwoFixed: .consume,
            .twoFingerClick: .consume,
        ])
        let fixed = [
            TrackpadContactSnapshot(identifier: 1, x: 0.4, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.6, y: 0.5),
        ]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 3, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.15
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.15, contacts: fixed))

        clock.value = 0.18
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.205
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.205, contacts: fixed))

        XCTAssertEqual(recognized.values.count, 1)
        XCTAssertEqual(recognized.values.first?.0, .twoFingerClick)
        coordinator.reset()
    }

    private func assertRejectedEpisodeWithoutNativePairDoesNotStealValidRetryPair(
        resolution: TrackpadNativeClickResolution,
        expectedPostedTypes: [CGEventType]
    ) throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            commitTipTapRecognition: { commits.append($0) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: resolution])
        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        // Episode A is too brief and produces no native pair.
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 2, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.12
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.12, contacts: fixed))

        // B qualifies after A's short pass-through quarantine. Its native pair arrives before B
        // releases or worker recognition, so A must not retain ownership for the full window.
        clock.value = 0.15
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.15,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.151
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 103))
        ))
        clock.value = 0.152
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 103))
        ))
        clock.value = 0.18
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.18, contacts: fixed))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: resolution
        ))

        XCTAssertEqual(commits.values.count, 1)
        XCTAssertEqual(postedTypes, expectedPostedTypes)
        coordinator.reset()
    }

    private func assertFixedFingerInstabilityImmediatelyReplaysBufferedTipTapPair(
        gesture: TrackpadGesture,
        fixed: [TrackpadContactSnapshot],
        added: TrackpadContactSnapshot,
        unstable: [TrackpadContactSnapshot]
    ) throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            commitTipTapRecognition: { commits.append($0) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([gesture: .consume])
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [added]
        ))

        clock.value = 0.111
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 901))
        ))
        clock.value = 0.112
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 901))
        ))
        XCTAssertTrue(postedTypes.isEmpty)

        clock.value = 0.12
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.12,
            contacts: unstable
        ))

        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])
        XCTAssertTrue(commits.values.isEmpty)
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

    private func assertRejectedClickArrivingAfterRetryStarts(
        resolution: TrackpadNativeClickResolution,
        expectedPostedTypes: [CGEventType]
    ) throws {
        let clock = LockedMiddleClickTestClock()
        var synthesizedCount = 0
        var postedTypes: [CGEventType] = []
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: { synthesizedCount += 1 },
            releaseMiddleButton: {},
            postEvent: { postedTypes.append($0.type) },
            eventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        coordinator.updateClickResolutions([.tipTapLeftOneFixed: resolution])
        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0, contacts: []))
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        clock.value = 0.10
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.10, contacts: fixed))

        // Episode A is rejected, then valid retry B starts before A's delayed native click pair.
        clock.value = 0.11
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: fixed + [.init(identifier: 2, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.12
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.12, contacts: fixed))
        clock.value = 0.135
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.135,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))

        clock.value = 0.138
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.139
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        XCTAssertEqual(postedTypes, [.leftMouseDown, .leftMouseUp])

        // B's own pair remains independently owned and is resolved exactly once.
        clock.value = 0.15
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.152
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        clock.value = 0.18
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.18, contacts: fixed))

        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: resolution
        ))
        XCTAssertEqual(postedTypes, expectedPostedTypes)
        XCTAssertEqual(synthesizedCount, 0)
        coordinator.reset()
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

    func testRecoveryResetSuppressesLongHeldOriginalUpForConsumedAndConvertedPairs() throws {
        for resolution in [TrackpadNativeClickResolution.consume, .middleClick] {
            let clock = LockedMiddleClickTestClock()
            var releasedMiddleButtonCount = 0
            let coordinator = TrackpadMiddleClickCoordinator(
                clock: { clock.value },
                synthesizeMiddleClick: {},
                releaseMiddleButton: { releasedMiddleButtonCount += 1 },
                postEvent: { _ in },
                eventOrigin: { event in
                    event.getIntegerValueField(.mouseEventNumber) == 101
                        ? .trackpad(deviceID: 1)
                        : .external
                }
            )
            coordinator.updateClickResolutions([.threeFingerTap: resolution])
            coordinator.observe(frame: .init(
                deviceID: 1,
                timestamp: 0,
                contacts: [
                    .init(identifier: 1, x: 0.3, y: 0.5),
                    .init(identifier: 2, x: 0.5, y: 0.5),
                    .init(identifier: 3, x: 0.7, y: 0.5),
                ]
            ))
            clock.value = 0.01
            XCTAssertTrue(coordinator.recognize(
                gesture: .threeFingerTap,
                deviceID: 1,
                resolution: resolution
            ))

            clock.value = 0.02
            let down = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDown,
                eventNumber: 101
            ))
            let downResult = coordinator.handleNativeEvent(type: .leftMouseDown, event: down)
            XCTAssertEqual(downResult == nil, resolution == .consume)

            coordinator.reset(preservingTerminalNativePairs: true)
            XCTAssertTrue(coordinator.hasTerminalNativePairsAwaitingUp)
            XCTAssertEqual(
                releasedMiddleButtonCount,
                resolution == .middleClick ? 1 : 0
            )
            XCTAssertEqual(
                coordinator.nativeClickOwnershipCountForTests(button: .left),
                1
            )

            clock.value = TrackpadMiddleClickCoordinator.nativeClickOwnershipWindow + 0.03
            let externalDown = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDown,
                eventNumber: 202
            ))
            XCTAssertNotNil(coordinator.handleNativeEvent(
                type: .leftMouseDown,
                event: externalDown
            ))
            let externalUp = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseUp,
                eventNumber: 202
            ))
            XCTAssertNotNil(coordinator.handleNativeEvent(
                type: .leftMouseUp,
                event: externalUp
            ))
            XCTAssertEqual(
                coordinator.nativeClickOwnershipCountForTests(button: .left),
                1
            )

            let originalUp = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseUp,
                eventNumber: 101
            ))
            XCTAssertNil(coordinator.handleNativeEvent(
                type: .leftMouseUp,
                event: originalUp
            ))
            XCTAssertFalse(coordinator.hasTerminalNativePairsAwaitingUp)
            XCTAssertEqual(
                coordinator.nativeClickOwnershipCountForTests(button: .left),
                0
            )
            coordinator.reset()
        }
    }

    func testLongHeldConsumedAndConvertedClicksSuppressTheirExactOriginalUp() throws {
        for resolution in [TrackpadNativeClickResolution.consume, .middleClick] {
            let clock = LockedMiddleClickTestClock()
            var releasedMiddleButtonCount = 0
            let coordinator = TrackpadMiddleClickCoordinator(
                clock: { clock.value },
                synthesizeMiddleClick: {},
                releaseMiddleButton: { releasedMiddleButtonCount += 1 },
                postEvent: { _ in },
                eventOrigin: { event in
                    event.getIntegerValueField(.mouseEventNumber) == 101
                        ? .trackpad(deviceID: 1)
                        : .external
                }
            )
            coordinator.updateClickResolutions([.threeFingerTap: resolution])
            coordinator.observe(frame: .init(
                deviceID: 1,
                timestamp: 0,
                contacts: [
                    .init(identifier: 1, x: 0.3, y: 0.5),
                    .init(identifier: 2, x: 0.5, y: 0.5),
                    .init(identifier: 3, x: 0.7, y: 0.5),
                ]
            ))
            clock.value = 0.01
            XCTAssertTrue(coordinator.recognize(
                gesture: .threeFingerTap,
                deviceID: 1,
                resolution: resolution
            ))

            clock.value = 0.02
            let originalDown = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDown,
                eventNumber: 101
            ))
            XCTAssertEqual(
                coordinator.handleNativeEvent(
                    type: .leftMouseDown,
                    event: originalDown
                ) == nil,
                resolution == .consume
            )
            XCTAssertEqual(
                coordinator.nativeClickOwnershipCountForTests(button: .left),
                1
            )

            clock.value = TrackpadMiddleClickCoordinator.nativeClickOwnershipWindow + 0.03
            let externalDown = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDown,
                eventNumber: 202
            ))
            XCTAssertNotNil(coordinator.handleNativeEvent(
                type: .leftMouseDown,
                event: externalDown
            ))
            let externalUp = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseUp,
                eventNumber: 202
            ))
            XCTAssertNotNil(coordinator.handleNativeEvent(
                type: .leftMouseUp,
                event: externalUp
            ))
            XCTAssertEqual(
                coordinator.nativeClickOwnershipCountForTests(button: .left),
                1
            )

            let originalUp = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseUp,
                eventNumber: 101
            ))
            XCTAssertNil(coordinator.handleNativeEvent(
                type: .leftMouseUp,
                event: originalUp
            ))
            XCTAssertEqual(
                coordinator.nativeClickOwnershipCountForTests(button: .left),
                0
            )
            XCTAssertEqual(
                releasedMiddleButtonCount,
                resolution == .middleClick ? 1 : 0
            )
            coordinator.reset()
        }
    }

    func testNativeClickOwnershipCapacityFailsOpenWithoutGrowingPastItsBound() throws {
        let coordinator = TrackpadMiddleClickCoordinator(
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            eventOrigin: { _ in .external }
        )

        for eventNumber in 1 ... 16 {
            let down = try XCTUnwrap(makeMouseEvent(
                type: .leftMouseDown,
                eventNumber: Int64(eventNumber)
            ))
            XCTAssertNotNil(coordinator.handleNativeEvent(
                type: .leftMouseDown,
                event: down
            ))
        }
        XCTAssertEqual(
            coordinator.nativeClickOwnershipCountForTests(button: .left),
            16
        )

        let overflowingDown = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseDown,
            eventNumber: 17
        ))
        XCTAssertNotNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: overflowingDown
        ))
        XCTAssertEqual(
            coordinator.nativeClickOwnershipCountForTests(button: .left),
            0
        )
        coordinator.reset()
    }

    func testRejectedDownKeepsItsEpisodeIdentityAcrossValidRetryAndDelayedUp() throws {
        let clock = LockedMiddleClickTestClock()
        let commits = LockedTipTapCommitRecorder()
        let coordinator = TrackpadMiddleClickCoordinator(
            clock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postEvent: { _ in },
            commitTipTapRecognition: { commits.append($0) },
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
            contacts: fixed + [.init(identifier: 2, x: 0.9, y: 0.5)]
        ))
        clock.value = 0.111
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 101))
        ))
        clock.value = 0.12
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.12, contacts: fixed))

        clock.value = 0.13
        coordinator.observe(frame: .init(
            deviceID: 1,
            timestamp: 0.13,
            contacts: fixed + [.init(identifier: 3, x: 0.1, y: 0.5)]
        ))
        clock.value = 0.18
        coordinator.observe(frame: .init(deviceID: 1, timestamp: 0.18, contacts: fixed))
        XCTAssertTrue(coordinator.recognize(
            gesture: .tipTapLeftOneFixed,
            deviceID: 1,
            resolution: .consume
        ))

        clock.value = 0.181
        let delayedRejectedUp = try XCTUnwrap(makeMouseEvent(
            type: .leftMouseUp,
            eventNumber: 101
        ))
        XCTAssertNotNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: delayedRejectedUp
        ))
        XCTAssertTrue(commits.values.isEmpty)

        clock.value = 0.19
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 102))
        ))
        clock.value = 0.191
        XCTAssertNil(coordinator.handleNativeEvent(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 102))
        ))
        XCTAssertEqual(commits.values.count, 1)
        coordinator.reset()
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
        case .rightMouseDown, .rightMouseUp: .right
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
