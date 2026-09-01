import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import TrackpadGesturesPlugin

final class TrackpadGestureTestingGeometryTests: XCTestCase {
    func testCoordinateProjectionClampsAndInvertsTrackpadY() {
        XCTAssertEqual(
            TrackpadCoordinateProjector.project(
                .init(identifier: 1, x: 0.25, y: 0.75),
                in: CGSize(width: 200, height: 100)
            ),
            CGPoint(x: 50, y: 25)
        )
        XCTAssertEqual(
            TrackpadCoordinateProjector.project(
                .init(identifier: 1, x: -1, y: 2),
                in: CGSize(width: 200, height: 100)
            ),
            CGPoint(x: 0, y: 0)
        )
    }

    func testTipTapGuideUsesProductionAnchorsAndThresholds() throws {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0, contacts: []))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.01, contacts: [fixed]))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.09, contacts: [fixed]))

        let snapshot = recognizer.testingSnapshot(for: .tipTapLeftOneFixed)
        let guide = TrackpadPracticeGuideGeometry.make(snapshot: snapshot)

        XCTAssertEqual(snapshot.phase, .armed)
        XCTAssertEqual(snapshot.anchorContacts, [fixed])
        XCTAssertEqual(
            guide.anchorToleranceRadius,
            snapshot.thresholds.fixedFingerMovement
        )
        XCTAssertEqual(
            guide.candidateToleranceRadius,
            snapshot.thresholds.tappingFingerMovement
        )
        let region = try XCTUnwrap(guide.regions.first)
        XCTAssertEqual(region.region, .left)
        XCTAssertEqual(region.xRange.lowerBound, 0)
        XCTAssertEqual(
            region.xRange.upperBound,
            fixed.x - snapshot.thresholds.tipTapSeparation,
            accuracy: 0.000_001
        )

        let anchorHalo = TrackpadMovementHaloGeometry.size(
                normalizedRadius: guide.anchorToleranceRadius,
                surfaceSize: CGSize(width: 400, height: 200)
            )
        XCTAssertEqual(anchorHalo.width, 28, accuracy: 0.000_001)
        XCTAssertEqual(anchorHalo.height, 14, accuracy: 0.000_001)
        let candidateHalo = TrackpadMovementHaloGeometry.size(
                normalizedRadius: guide.candidateToleranceRadius,
                surfaceSize: CGSize(width: 400, height: 200)
            )
        XCTAssertEqual(candidateHalo.width, 36, accuracy: 0.000_001)
        XCTAssertEqual(candidateHalo.height, 18, accuracy: 0.000_001)
    }

    func testTimingProgressReportsRemainingIntervalAndClampsAtBounds() {
        let active = TrackpadGestureTimingProgress.make(
            startedAt: 10,
            deadline: 10.32,
            now: 10.12
        )
        XCTAssertEqual(active.fraction, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(active.remaining, 0.20, accuracy: 0.000_001)

        XCTAssertEqual(
            TrackpadGestureTimingProgress.make(startedAt: 10, deadline: 10.32, now: 9).fraction,
            0
        )
        let expired = TrackpadGestureTimingProgress.make(
            startedAt: 10,
            deadline: 10.32,
            now: 11
        )
        XCTAssertEqual(expired.fraction, 1)
        XCTAssertEqual(expired.remaining, 0)
    }

    func testImmediateTipTapReleaseRejectionsSurfaceOnceBeforeRearming() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0, contacts: []))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.01, contacts: [fixed]))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.09, contacts: [fixed]))

        let brief = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        _ = recognizer.process(.init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [fixed, brief]
        ))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.11, contacts: [fixed]))

        let briefRejection = recognizer.testingSnapshot(for: .tipTapLeftOneFixed)
        XCTAssertEqual(briefRejection.phase, .rejected(.tooBrief))
        XCTAssertEqual(briefRejection.rejectionSequence, 1)
        XCTAssertEqual(
            recognizer.testingSnapshot(for: .tipTapLeftOneFixed).phase,
            .armed
        )

        let long = TrackpadContactSnapshot(identifier: 3, x: 0.1, y: 0.5)
        _ = recognizer.process(.init(
            deviceID: 1,
            timestamp: 0.20,
            contacts: [fixed, long]
        ))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.60, contacts: [fixed]))

        let longRejection = recognizer.testingSnapshot(for: .tipTapLeftOneFixed)
        XCTAssertEqual(longRejection.phase, .rejected(.tooLong))
        XCTAssertEqual(longRejection.rejectionSequence, 2)
        XCTAssertEqual(
            recognizer.testingSnapshot(for: .tipTapLeftOneFixed).phase,
            .armed
        )
    }

    func testTipTapRejectionGuidanceIsSpecificAndActionableForEveryReason() {
        let localization = PluginLocalization(bundle: Bundle.main)
        let reasons: [TipTapEpisodeRejectionReason] = [
            .fixedFingersNotSettled,
            .fixedFingersBecameUnstable,
            .tooBrief,
            .tooLong,
            .movedTooFar,
            .wrongRegion,
            .extraContact,
        ]
        let messages = reasons.map { $0.practiceStatusText(localization: localization) }

        XCTAssertEqual(Set(messages).count, reasons.count)
        XCTAssertFalse(messages[2].contains("抬起新增手指"))
        XCTAssertTrue(messages[1].contains("所有手指"))
        XCTAssertTrue(messages[5].contains("高亮区域"))
    }

    func testTipTapGuideWaitsForCompleteStableAnchorsAndExplainsUnavailableMiddle() {
        let thresholds = TrackpadGestureRecognitionThresholds.default
        let partial = TrackpadGestureRecognitionSnapshot(
            gesture: .tipTapLeftTwoFixed,
            phase: .acquiring,
            anchorContacts: [.init(identifier: 1, x: 0.4, y: 0.5)],
            candidateContacts: [],
            requiredContactCount: 3,
            movementTolerance: thresholds.fixedFingerMovement,
            startedAt: 0,
            deadline: 0.1,
            thresholds: thresholds,
            rejectionSequence: 0
        )
        let partialGuide = TrackpadPracticeGuideGeometry.make(snapshot: partial)
        XCTAssertEqual(
            partialGuide.availability,
            .waitingForAnchors(required: 2, current: 1)
        )
        XCTAssertTrue(partialGuide.regions.isEmpty)
        XCTAssertEqual(partialGuide.unavailableRanges, [0 ... 1])

        let narrowMiddle = TrackpadGestureRecognitionSnapshot(
            gesture: .tipTapMiddleTwoFixed,
            phase: .armed,
            anchorContacts: [
                .init(identifier: 1, x: 0.49, y: 0.5),
                .init(identifier: 2, x: 0.51, y: 0.5),
            ],
            candidateContacts: [],
            requiredContactCount: 3,
            movementTolerance: thresholds.tappingFingerMovement,
            startedAt: nil,
            deadline: nil,
            thresholds: thresholds,
            rejectionSequence: 0
        )
        let narrowGuide = TrackpadPracticeGuideGeometry.make(snapshot: narrowMiddle)
        XCTAssertEqual(narrowGuide.availability, .middleRequiresWiderSpan)
        XCTAssertTrue(narrowGuide.regions.isEmpty)
        XCTAssertEqual(narrowGuide.unavailableRanges, [0 ... 1])
        XCTAssertFalse(
            narrowGuide.availability.statusText(
                localization: PluginLocalization(bundle: Bundle.main)
            ).isEmpty
        )
    }

    func testTerminalTipTapRejectionRetainsFixedAndAddedContactRoles() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        let added = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0, contacts: []))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.01, contacts: [fixed]))
        _ = recognizer.process(.init(deviceID: 1, timestamp: 0.09, contacts: [fixed]))
        _ = recognizer.process(.init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [fixed, added]
        ))
        let movedFixed = TrackpadContactSnapshot(identifier: 1, x: 0.7, y: 0.5)
        _ = recognizer.process(.init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: [movedFixed, added]
        ))

        let rejection = recognizer.testingSnapshot(for: .tipTapLeftOneFixed)
        XCTAssertEqual(rejection.phase, .rejected(.fixedFingersBecameUnstable))
        XCTAssertEqual(rejection.anchorContacts.map(\.identifier), [1])
        XCTAssertEqual(rejection.candidateContacts.map(\.identifier), [2])
        XCTAssertEqual(
            TrackpadContactRoleResolver.resolve(movedFixed, recognition: rejection),
            .fixed
        )
        XCTAssertEqual(
            TrackpadContactRoleResolver.resolve(added, recognition: rejection),
            .added
        )
    }

    func testRecoverableTipTapRejectionsKeepStillDownAddedContactRoles() {
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        let validAdded = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        let wrongRegion = TrackpadContactSnapshot(identifier: 2, x: 0.9, y: 0.5)
        let movedAdded = TrackpadContactSnapshot(identifier: 2, x: 0.25, y: 0.5)
        let extraAdded = TrackpadContactSnapshot(identifier: 3, x: 0.2, y: 0.5)

        func armedRecognizer() -> TipTapRecognizer {
            var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
            _ = recognizer.process(.init(deviceID: 1, timestamp: 0, contacts: []))
            _ = recognizer.process(.init(deviceID: 1, timestamp: 0.01, contacts: [fixed]))
            _ = recognizer.process(.init(deviceID: 1, timestamp: 0.09, contacts: [fixed]))
            return recognizer
        }

        var wrongRegionRecognizer = armedRecognizer()
        _ = wrongRegionRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [fixed, wrongRegion]
        ))
        assertAddedRoles(
            [wrongRegion],
            snapshot: wrongRegionRecognizer.testingSnapshot(for: .tipTapLeftOneFixed),
            reason: .wrongRegion
        )

        var movedRecognizer = armedRecognizer()
        _ = movedRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [fixed, validAdded]
        ))
        _ = movedRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.11,
            contacts: [fixed, movedAdded]
        ))
        assertAddedRoles(
            [movedAdded],
            snapshot: movedRecognizer.testingSnapshot(for: .tipTapLeftOneFixed),
            reason: .movedTooFar
        )

        var longRecognizer = armedRecognizer()
        _ = longRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [fixed, validAdded]
        ))
        _ = longRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.50,
            contacts: [fixed, validAdded]
        ))
        assertAddedRoles(
            [validAdded],
            snapshot: longRecognizer.testingSnapshot(for: .tipTapLeftOneFixed),
            reason: .tooLong
        )

        var extraRecognizer = armedRecognizer()
        _ = extraRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.10,
            contacts: [fixed, validAdded, extraAdded]
        ))
        assertAddedRoles(
            [validAdded, extraAdded],
            snapshot: extraRecognizer.testingSnapshot(for: .tipTapLeftOneFixed),
            reason: .extraContact
        )

        var unsettledRecognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = unsettledRecognizer.process(.init(deviceID: 1, timestamp: 0, contacts: []))
        _ = unsettledRecognizer.process(.init(deviceID: 1, timestamp: 0.01, contacts: [fixed]))
        _ = unsettledRecognizer.process(.init(
            deviceID: 1,
            timestamp: 0.02,
            contacts: [fixed, validAdded]
        ))
        assertAddedRoles(
            [validAdded],
            snapshot: unsettledRecognizer.testingSnapshot(for: .tipTapLeftOneFixed),
            reason: .fixedFingersNotSettled
        )
    }

    func testTerminalRejectionAndCommittedSuccessTakePriorityOverUnavailableGuide() {
        let thresholds = TrackpadGestureRecognitionThresholds.default
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        let rejection = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [fixed],
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .tipTapLeftOneFixed,
                phase: .rejected(.fixedFingersBecameUnstable),
                anchorContacts: [fixed],
                candidateContacts: [],
                requiredContactCount: 2,
                movementTolerance: thresholds.tappingFingerMovement,
                startedAt: nil,
                deadline: nil,
                thresholds: thresholds,
                rejectionSequence: 1
            )
        )

        XCTAssertEqual(
            TrackpadGestureTestingStatusPresentationResolver.resolve(
                snapshot: rejection,
                retainedRecognition: nil
            ),
            .status(.phase(
                .rejected(.fixedFingersBecameUnstable),
                gesture: .tipTapLeftOneFixed
            ))
        )
        XCTAssertEqual(
            TrackpadGestureTestingStatusPresentationResolver.resolve(
                snapshot: rejection,
                retainedRecognition: .tipTapLeftOneFixed
            ),
            .status(.phase(
                .rejected(.fixedFingersBecameUnstable),
                gesture: .tipTapLeftOneFixed
            ))
        )

        let narrowAnchors = [
            TrackpadContactSnapshot(identifier: 1, x: 0.49, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.51, y: 0.5),
        ]
        let unavailableGuide = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 2,
            contacts: narrowAnchors,
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .tipTapMiddleTwoFixed,
                phase: .armed,
                anchorContacts: narrowAnchors,
                candidateContacts: [],
                requiredContactCount: 3,
                movementTolerance: thresholds.tappingFingerMovement,
                startedAt: nil,
                deadline: nil,
                thresholds: thresholds,
                rejectionSequence: 0
            )
        )
        XCTAssertEqual(
            TrackpadPracticeGuideGeometry.make(
                snapshot: unavailableGuide.recognition!
            ).availability,
            .middleRequiresWiderSpan
        )
        XCTAssertEqual(
            TrackpadGestureTestingStatusPresentationResolver.resolve(
                snapshot: unavailableGuide,
                retainedRecognition: .tipTapMiddleTwoFixed
            ),
            .status(.recognized(.tipTapMiddleTwoFixed))
        )
    }

    func testTestingModeAccessibilityStateIdentifiesOnlyTheActiveMode() {
        let all = TrackpadGestureTestingModeAccessibilityState(mode: .allGestures)
        XCTAssertTrue(all.isAllGesturesSelected)
        XCTAssertNil(all.selectedPracticeGesture)
        XCTAssertFalse(all.isPracticeSelected(.threeFingerTap))

        let practice = TrackpadGestureTestingModeAccessibilityState(
            mode: .practice(.threeFingerTap)
        )
        XCTAssertFalse(practice.isAllGesturesSelected)
        XCTAssertEqual(practice.selectedPracticeGesture, .threeFingerTap)
        XCTAssertTrue(practice.isPracticeSelected(.threeFingerTap))
        XCTAssertFalse(practice.isPracticeSelected(.fourFingerTap))
    }

    private func assertAddedRoles(
        _ contacts: [TrackpadContactSnapshot],
        snapshot: TrackpadGestureRecognitionSnapshot,
        reason: TipTapEpisodeRejectionReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.phase, .rejected(reason), file: file, line: line)
        XCTAssertEqual(
            Set(snapshot.candidateContacts.map(\.identifier)),
            Set(contacts.map(\.identifier)),
            file: file,
            line: line
        )
        for contact in contacts {
            XCTAssertEqual(
                TrackpadContactRoleResolver.resolve(contact, recognition: snapshot),
                .added,
                file: file,
                line: line
            )
        }
    }
}

final class TrackpadGestureTestingRelayTests: XCTestCase {
    func testEmissionTokenBecomesStaleAcrossModeAndSameModeRestart() throws {
        let recorder = LockedTestingEmissionRecorder()
        let relay = TrackpadGestureTestSnapshotRelay(handler: { recorder.append($0) })
        relay.update(mode: .practice(.threeFingerTap))
        let token = try XCTUnwrap(relay.currentToken())
        relay.offer(
            TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: 1,
                contacts: [],
                recognized: [],
                recognition: TrackpadGestureRecognitionSnapshot(
                    gesture: .threeFingerTap,
                    phase: .ready,
                    anchorContacts: [],
                    candidateContacts: [],
                    requiredContactCount: 3,
                    movementTolerance: 0.035,
                    startedAt: nil,
                    deadline: nil,
                    thresholds: .default,
                    rejectionSequence: 0
                )
            ),
            token: token,
            recognitionGeneration: 7,
            recognitionDeviceGeneration: 9
        )

        let emission = try XCTUnwrap(recorder.values.first)
        XCTAssertTrue(relay.isCurrent(emission.token))
        XCTAssertEqual(emission.recognitionGeneration, 7)
        XCTAssertEqual(emission.recognitionDeviceGeneration, 9)

        relay.update(mode: .practice(.fourFingerTap))
        XCTAssertFalse(relay.isCurrent(emission.token))
        relay.update(mode: nil)
        relay.update(mode: .practice(.threeFingerTap))
        XCTAssertFalse(relay.isCurrent(emission.token))
    }
}

final class TrackpadGestureSnapshotCoalescerTests: XCTestCase {
    func testCoalescerRateLimitsEachDeviceIndependently() throws {
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let first = snapshot(deviceID: 1, timestamp: 1, contactX: 0.1)
        let second = snapshot(deviceID: 1, timestamp: 2, contactX: 0.2)
        let otherFirst = snapshot(deviceID: 2, timestamp: 1, contactX: 0.8)
        let otherSecond = snapshot(deviceID: 2, timestamp: 2, contactX: 0.9)

        XCTAssertEqual(coalescer.offer(first, at: 0).snapshot, first)
        XCTAssertEqual(coalescer.offer(otherFirst, at: 0).snapshot, otherFirst)
        XCTAssertNil(coalescer.offer(second, at: 0.01).snapshot)
        XCTAssertNil(coalescer.offer(otherSecond, at: 0.01).snapshot)

        XCTAssertNil(coalescer.takePending(deviceID: 1, at: 0.03).snapshot)
        XCTAssertNil(coalescer.takePending(deviceID: 2, at: 0.03).snapshot)
        XCTAssertEqual(
            coalescer.takePending(deviceID: 1, at: 1 / 30).snapshot,
            second
        )
        XCTAssertEqual(
            coalescer.takePending(deviceID: 2, at: 1 / 30).snapshot,
            otherSecond
        )
    }

    func testResetClearsPerDeviceRateLimitsAndPendingSnapshots() {
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let first = snapshot(deviceID: 1, timestamp: 1, contactX: 0.1)
        let otherFirst = snapshot(deviceID: 2, timestamp: 1, contactX: 0.8)
        XCTAssertEqual(coalescer.offer(first, at: 0).snapshot, first)
        XCTAssertEqual(coalescer.offer(otherFirst, at: 0).snapshot, otherFirst)
        XCTAssertNil(coalescer.offer(
            snapshot(deviceID: 1, timestamp: 2, contactX: 0.2),
            at: 0.01
        ).snapshot)
        XCTAssertNil(coalescer.offer(
            snapshot(deviceID: 2, timestamp: 2, contactX: 0.9),
            at: 0.01
        ).snapshot)

        coalescer.reset()

        XCTAssertNil(coalescer.takePending(deviceID: 1, at: 0.011).snapshot)
        XCTAssertNil(coalescer.takePending(deviceID: 2, at: 0.011).snapshot)
        let fresh = snapshot(deviceID: 1, timestamp: 3, contactX: 0.3)
        let otherFresh = snapshot(deviceID: 2, timestamp: 3, contactX: 0.7)
        XCTAssertEqual(coalescer.offer(fresh, at: 0.011).snapshot, fresh)
        XCTAssertEqual(coalescer.offer(otherFresh, at: 0.011).snapshot, otherFresh)
    }

    func testCoalescerDoesNotErasePendingTipTapRejectionWithRapidRearmFrame() throws {
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let initial = snapshot(deviceID: 1, timestamp: 1, contactX: 0.5)
        XCTAssertEqual(coalescer.offer(initial, at: 0).snapshot, initial)

        let rejection = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 2,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .tipTapLeftOneFixed,
                phase: .rejected(.tooBrief),
                anchorContacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
                candidateContacts: [],
                requiredContactCount: 2,
                movementTolerance: 0.045,
                startedAt: nil,
                deadline: nil,
                thresholds: .default,
                rejectionSequence: 1
            )
        )
        let rearmed = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 3,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .tipTapLeftOneFixed,
                phase: .armed,
                anchorContacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
                candidateContacts: [],
                requiredContactCount: 2,
                movementTolerance: 0.045,
                startedAt: nil,
                deadline: nil,
                thresholds: .default,
                rejectionSequence: 1
            )
        )

        XCTAssertNil(coalescer.offer(rejection, at: 0.01).snapshot)
        XCTAssertNil(coalescer.offer(rearmed, at: 0.02).snapshot)
        let rejectionDelivery = coalescer.takePending(deviceID: 1, at: 1 / 30)
        XCTAssertEqual(try XCTUnwrap(rejectionDelivery.snapshot), rejection)
        XCTAssertEqual(
            try XCTUnwrap(rejectionDelivery.delay),
            1 / 30,
            accuracy: 0.000_001
        )

        let rearmedDelivery = coalescer.takePending(deviceID: 1, at: 2 / 30)
        XCTAssertEqual(try XCTUnwrap(rearmedDelivery.snapshot), rearmed)
        XCTAssertNil(rearmedDelivery.delay)
    }

    func testCoalescerPreservesTwoTestingEventsBeforeNewestLiveSnapshot() throws {
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let initial = snapshot(deviceID: 1, timestamp: 1, contactX: 0.5)
        XCTAssertEqual(
            coalescer.offer(initial, recognitionGeneration: 1, at: 0).snapshot,
            initial
        )

        let recognized = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 2,
            contacts: initial.contacts,
            recognized: [.threeFingerTap],
            recognition: nil
        )
        let rejected = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 3,
            contacts: initial.contacts,
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .tipTapLeftOneFixed,
                phase: .rejected(.tooBrief),
                anchorContacts: initial.contacts,
                candidateContacts: [],
                requiredContactCount: 2,
                movementTolerance: 0.045,
                startedAt: nil,
                deadline: nil,
                thresholds: .default,
                rejectionSequence: 1
            )
        )
        let live1 = snapshot(deviceID: 1, timestamp: 4, contactX: 0.4)
        let live2 = snapshot(deviceID: 1, timestamp: 5, contactX: 0.6)

        XCTAssertNil(coalescer.offer(
            recognized,
            recognitionGeneration: 2,
            at: 0.005
        ).snapshot)
        XCTAssertNil(coalescer.offer(
            rejected,
            recognitionGeneration: 3,
            at: 0.010
        ).snapshot)
        XCTAssertNil(coalescer.offer(
            live1,
            recognitionGeneration: 4,
            at: 0.015
        ).snapshot)
        XCTAssertNil(coalescer.offer(
            live2,
            recognitionGeneration: 5,
            at: 0.020
        ).snapshot)

        let first = coalescer.takePending(deviceID: 1, at: 1 / 30)
        XCTAssertEqual(first.snapshot, recognized)
        XCTAssertEqual(first.recognitionGeneration, 2)
        XCTAssertEqual(try XCTUnwrap(first.delay), 1 / 30, accuracy: 0.000_001)

        let second = coalescer.takePending(deviceID: 1, at: 2 / 30)
        XCTAssertEqual(second.snapshot, rejected)
        XCTAssertEqual(second.recognitionGeneration, 3)
        XCTAssertEqual(try XCTUnwrap(second.delay), 1 / 30, accuracy: 0.000_001)

        let third = coalescer.takePending(deviceID: 1, at: 3 / 30)
        XCTAssertEqual(third.snapshot, live2)
        XCTAssertEqual(third.recognitionGeneration, 5)
        XCTAssertNil(third.delay)
    }

    func testCoalescerBoundsTerminalEventsAndKeepsNewestLiveSnapshot() throws {
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let initial = snapshot(deviceID: 1, timestamp: 1, contactX: 0.5)
        XCTAssertEqual(coalescer.offer(initial, at: 0).snapshot, initial)

        let eventLimit = TrackpadGestureSnapshotCoalescer
            .maximumPendingTestingEventsPerDevice
        let offeredEventCount = eventLimit + 20
        var offeredEvents: [TrackpadGestureTestSnapshot] = []
        for index in 0 ..< offeredEventCount {
            let event = TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: TimeInterval(index + 2),
                contacts: initial.contacts,
                recognized: [.threeFingerTap],
                recognition: nil
            )
            offeredEvents.append(event)
            XCTAssertNil(coalescer.offer(
                event,
                recognitionGeneration: UInt64(index + 2),
                at: 0.001
            ).snapshot)
        }

        XCTAssertEqual(
            coalescer.pendingTestingEventCountForTests(deviceID: 1),
            eventLimit
        )

        let newestLive = snapshot(deviceID: 1, timestamp: 1_000, contactX: 0.8)
        XCTAssertNil(coalescer.offer(
            newestLive,
            recognitionGeneration: 1_000,
            at: 0.001
        ).snapshot)
        XCTAssertEqual(
            coalescer.pendingTestingEventCountForTests(deviceID: 1),
            eventLimit
        )

        let expectedEvents = Array(offeredEvents.suffix(eventLimit))
        for (index, expected) in expectedEvents.enumerated() {
            let delivery = coalescer.takePending(
                deviceID: 1,
                at: TimeInterval(index + 1) * 0.034
            )
            XCTAssertEqual(delivery.snapshot, expected)
            XCTAssertEqual(
                delivery.recognitionGeneration,
                UInt64(offeredEventCount - eventLimit + index + 2)
            )
            XCTAssertEqual(
                try XCTUnwrap(delivery.delay),
                1 / 30,
                accuracy: 0.000_001
            )
        }

        let liveDelivery = coalescer.takePending(
            deviceID: 1,
            at: TimeInterval(eventLimit + 1) * 0.034
        )
        XCTAssertEqual(liveDelivery.snapshot, newestLive)
        XCTAssertEqual(liveDelivery.recognitionGeneration, 1_000)
        XCTAssertNil(liveDelivery.delay)
    }

    func testCoalescerQueuesOneEventForSustainedRejectionSequence() throws {
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let initial = snapshot(deviceID: 1, timestamp: 1, contactX: 0.5)
        XCTAssertEqual(coalescer.offer(initial, at: 0).snapshot, initial)

        func rejection(timestamp: TimeInterval, sequence: UInt64) -> TrackpadGestureTestSnapshot {
            TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: timestamp,
                contacts: initial.contacts,
                recognized: [],
                recognition: TrackpadGestureRecognitionSnapshot(
                    gesture: .tipTapLeftOneFixed,
                    phase: .rejected(.wrongRegion),
                    anchorContacts: initial.contacts,
                    candidateContacts: [],
                    requiredContactCount: 2,
                    movementTolerance: 0.045,
                    startedAt: nil,
                    deadline: nil,
                    thresholds: .default,
                    rejectionSequence: sequence
                )
            )
        }

        let firstRejection = rejection(timestamp: 2, sequence: 1)
        XCTAssertNil(coalescer.offer(firstRejection, at: 0.001).snapshot)
        var latestRejection = firstRejection
        for index in 1...100 {
            latestRejection = rejection(timestamp: 2 + Double(index), sequence: 1)
            XCTAssertNil(
                coalescer.offer(latestRejection, at: 0.001 + Double(index) / 100_000).snapshot
            )
        }

        let event = coalescer.takePending(deviceID: 1, at: 1 / 30)
        XCTAssertEqual(event.snapshot, firstRejection)
        XCTAssertNotNil(event.delay)

        let latest = coalescer.takePending(deviceID: 1, at: 2 / 30)
        XCTAssertEqual(latest.snapshot, latestRejection)
        XCTAssertNil(latest.delay)
        XCTAssertNil(coalescer.takePending(deviceID: 1, at: 3 / 30).snapshot)

        let secondSequence = rejection(timestamp: 200, sequence: 2)
        XCTAssertEqual(
            coalescer.offer(secondSequence, at: 4 / 30).snapshot,
            secondSequence
        )
    }

    private func snapshot(
        deviceID: UInt64,
        timestamp: TimeInterval,
        contactX: Double
    ) -> TrackpadGestureTestSnapshot {
        TrackpadGestureTestSnapshot(
            deviceID: deviceID,
            descriptor: nil,
            timestamp: timestamp,
            contacts: [.init(identifier: 1, x: contactX, y: 0.5)],
            recognized: [],
            recognition: nil
        )
    }
}

@MainActor
final class TrackpadGestureTestingModelTests: XCTestCase {
    func testModelKeepsDevicesIsolatedAndRespectsExplicitSelection() {
        let model = TrackpadGestureTestingModel()
        model.begin(.allGestures)
        let builtIn = snapshot(deviceID: 1, timestamp: 1, contacts: [
            .init(identifier: 1, x: 0.2, y: 0.5),
        ])
        let external = snapshot(deviceID: 2, timestamp: 2, contacts: [
            .init(identifier: 2, x: 0.8, y: 0.5),
        ])

        model.apply(builtIn)
        model.apply(external)
        XCTAssertEqual(model.selectedDeviceID, 2)
        XCTAssertEqual(model.snapshotsByDevice[1]?.contacts, builtIn.contacts)
        XCTAssertEqual(model.snapshotsByDevice[2]?.contacts, external.contacts)

        model.selectDevice(1)
        model.recordRecognized(.threeFingerTap, deviceID: 2)
        model.apply(snapshot(deviceID: 2, timestamp: 3, contacts: []))
        XCTAssertEqual(model.selectedDeviceID, 1)
        XCTAssertEqual(model.snapshotsByDevice[2]?.contacts, [])
        XCTAssertNil(model.selectedRecognizedGesture)

        model.recordRecognized(.fourFingerTap, deviceID: 1)
        XCTAssertEqual(model.selectedRecognizedGesture, .fourFingerTap)
    }

    func testAcquisitionProgressUsesTheProductionCancellationDeadline() throws {
        let first = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        var tap = MultiFingerTapRecognizer(fingerCount: 3)
        _ = tap.process(.init(deviceID: 1, timestamp: 0, contacts: []))
        _ = tap.process(.init(deviceID: 1, timestamp: 0.01, contacts: [first]))
        let tapSnapshot = tap.testingSnapshot(for: .threeFingerTap)

        XCTAssertEqual(tapSnapshot.phase, .acquiring)
        XCTAssertEqual(tapSnapshot.startedAt, 0.01)
        XCTAssertEqual(
            try XCTUnwrap(tapSnapshot.deadline),
            0.01 + tapSnapshot.thresholds.acquisitionMaximumDuration,
            accuracy: 0.000_001
        )

        var longTouch = LongTouchRecognizer(fingerCount: 3)
        _ = longTouch.process(.init(deviceID: 1, timestamp: 0, contacts: []))
        _ = longTouch.process(.init(deviceID: 1, timestamp: 0.01, contacts: [first]))
        let longTouchSnapshot = longTouch.testingSnapshot(for: .threeFingerLongTouch)

        XCTAssertEqual(longTouchSnapshot.phase, .acquiring)
        XCTAssertEqual(longTouchSnapshot.startedAt, 0.01)
        XCTAssertEqual(
            try XCTUnwrap(longTouchSnapshot.deadline),
            0.01 + longTouchSnapshot.thresholds.acquisitionMaximumDuration,
            accuracy: 0.000_001
        )
    }

    func testZeroContactFrameClearsSurfaceAndStoppingClearsAllMemoryState() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.threeFingerTap))
        model.apply(snapshot(deviceID: 1, timestamp: 1, contacts: [
            .init(identifier: 1, x: 0.2, y: 0.5),
        ]))

        model.apply(snapshot(deviceID: 1, timestamp: 2, contacts: []))
        XCTAssertEqual(model.selectedSnapshot?.contacts, [])

        model.stop()
        XCTAssertNil(model.mode)
        XCTAssertNil(model.selectedDeviceID)
        XCTAssertTrue(model.snapshotsByDevice.isEmpty)
    }

    func testRetainedSuccessDoesNotMaskLaterLiveAttemptState() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.threeFingerTap))
        model.apply(snapshot(deviceID: 1, timestamp: 1, contacts: []))
        model.recordRecognized(.threeFingerTap, deviceID: 1, at: 1)

        let live = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 2,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .threeFingerTap,
                phase: .tracking,
                anchorContacts: [],
                candidateContacts: [],
                requiredContactCount: 3,
                movementTolerance: 0.035,
                startedAt: 2,
                deadline: 2.22,
                thresholds: .default,
                rejectionSequence: 0
            )
        )
        model.apply(live)

        XCTAssertNil(model.selectedRecognizedGesture)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture
            ),
            .phase(.tracking, gesture: .threeFingerTap)
        )
    }

    func testRepeatedSuccessThenLiveRejectionUsesTheCurrentAttemptState() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.tipTapLeftOneFixed))
        model.apply(snapshot(deviceID: 1, timestamp: 1, contacts: []))
        model.recordRecognized(.tipTapLeftOneFixed, deviceID: 1, at: 1)
        model.recordRecognized(.tipTapLeftOneFixed, deviceID: 1, at: 1.1)

        model.apply(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 2,
            contacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
            recognized: [],
            recognition: TrackpadGestureRecognitionSnapshot(
                gesture: .tipTapLeftOneFixed,
                phase: .rejected(.tooBrief),
                anchorContacts: [.init(identifier: 1, x: 0.5, y: 0.5)],
                candidateContacts: [],
                requiredContactCount: 2,
                movementTolerance: 0.045,
                startedAt: nil,
                deadline: nil,
                thresholds: .default,
                rejectionSequence: 1
            )
        ))

        XCTAssertNil(model.selectedRecognizedGesture)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture
            ),
            .phase(.rejected(.tooBrief), gesture: .tipTapLeftOneFixed)
        )
    }

    func testRetainedRejectionSurvivesIdleFramesAndClearsAtNextAttemptOrReset() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.tipTapLeftOneFixed))
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        let added = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        func snapshot(
            timestamp: TimeInterval,
            contacts: [TrackpadContactSnapshot],
            phase: TrackpadGestureRecognitionPhase,
            rejectionSequence: UInt64
        ) -> TrackpadGestureTestSnapshot {
            TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: timestamp,
                contacts: contacts,
                recognized: [],
                recognition: TrackpadGestureRecognitionSnapshot(
                    gesture: .tipTapLeftOneFixed,
                    phase: phase,
                    anchorContacts: contacts.filter { $0.identifier == fixed.identifier },
                    candidateContacts: contacts.filter { $0.identifier != fixed.identifier },
                    requiredContactCount: 2,
                    movementTolerance: 0.045,
                    startedAt: nil,
                    deadline: nil,
                    thresholds: .default,
                    rejectionSequence: rejectionSequence
                )
            )
        }

        model.apply(snapshot(
            timestamp: 1,
            contacts: [fixed],
            phase: .rejected(.tooBrief),
            rejectionSequence: 1
        ))
        let briefAnnouncement = model.latestRejectionAnnouncement
        model.apply(snapshot(
            timestamp: 2,
            contacts: [fixed],
            phase: .armed,
            rejectionSequence: 1
        ))

        XCTAssertEqual(model.latestRejectionAnnouncement, briefAnnouncement)
        XCTAssertEqual(model.selectedRejection?.reason, .tooBrief)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: nil,
                retainedRejection: model.selectedRejection
            ),
            .phase(.rejected(.tooBrief), gesture: .tipTapLeftOneFixed)
        )

        model.apply(snapshot(
            timestamp: 3,
            contacts: [fixed, added],
            phase: .candidate,
            rejectionSequence: 1
        ))
        XCTAssertNil(model.selectedRejection)

        model.apply(snapshot(
            timestamp: 4,
            contacts: [fixed],
            phase: .rejected(.fixedFingersBecameUnstable),
            rejectionSequence: 2
        ))
        model.apply(snapshot(
            timestamp: 5,
            contacts: [fixed],
            phase: .waitingForReset,
            rejectionSequence: 2
        ))
        XCTAssertEqual(
            model.selectedRejection?.reason,
            .fixedFingersBecameUnstable
        )

        model.apply(snapshot(
            timestamp: 6,
            contacts: [],
            phase: .ready,
            rejectionSequence: 2
        ))
        XCTAssertNil(model.selectedRejection)
    }

    func testRejectionAnnouncementPolicyTriggersOnlyForChangedRejection() {
        let rejection = TrackpadGestureTestingRejection(
            deviceID: 1,
            gesture: .tipTapLeftOneFixed,
            reason: .tooBrief,
            sequence: 1
        )
        XCTAssertTrue(TrackpadGestureTestingRejectionAnnouncementPolicy.shouldAnnounce(
            previous: nil,
            current: rejection
        ))
        XCTAssertFalse(TrackpadGestureTestingRejectionAnnouncementPolicy.shouldAnnounce(
            previous: rejection,
            current: rejection
        ))
        XCTAssertFalse(TrackpadGestureTestingRejectionAnnouncementPolicy.shouldAnnounce(
            previous: rejection,
            current: nil
        ))
    }

    func testIdenticalFirstRejectionsOnDifferentDevicesEachRequestAnnouncement() throws {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.tipTapLeftOneFixed))
        func rejectionSnapshot(deviceID: UInt64) -> TrackpadGestureTestSnapshot {
            let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
            return TrackpadGestureTestSnapshot(
                deviceID: deviceID,
                descriptor: nil,
                timestamp: 1,
                contacts: [fixed],
                recognized: [],
                recognition: TrackpadGestureRecognitionSnapshot(
                    gesture: .tipTapLeftOneFixed,
                    phase: .rejected(.tooBrief),
                    anchorContacts: [fixed],
                    candidateContacts: [],
                    requiredContactCount: 2,
                    movementTolerance: 0.045,
                    startedAt: nil,
                    deadline: nil,
                    thresholds: .default,
                    rejectionSequence: 1
                )
            )
        }

        model.apply(rejectionSnapshot(deviceID: 1))
        let first = try XCTUnwrap(model.latestRejectionAnnouncement)
        model.selectDevice(1)
        model.apply(rejectionSnapshot(deviceID: 2))
        let second = try XCTUnwrap(model.latestRejectionAnnouncement)

        XCTAssertEqual(first.deviceID, 1)
        XCTAssertEqual(second.deviceID, 2)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(TrackpadGestureTestingRejectionAnnouncementPolicy.shouldAnnounce(
            previous: first,
            current: second
        ))
        XCTAssertEqual(model.selectedDeviceID, 1)
        XCTAssertEqual(model.selectedRejection?.deviceID, 1)
        XCTAssertEqual(model.selectedRejection?.reason, .tooBrief)

        model.apply(rejectionSnapshot(deviceID: 2))
        XCTAssertEqual(model.latestRejectionAnnouncement, second)
    }

    func testCommittedTipTapSuccessSurvivesIdleFixedFramesUntilNextEpisode() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.tipTapLeftOneFixed))
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        func snapshot(
            timestamp: TimeInterval,
            contacts: [TrackpadContactSnapshot],
            phase: TrackpadGestureRecognitionPhase
        ) -> TrackpadGestureTestSnapshot {
            TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: timestamp,
                contacts: contacts,
                recognized: [],
                recognition: TrackpadGestureRecognitionSnapshot(
                    gesture: .tipTapLeftOneFixed,
                    phase: phase,
                    anchorContacts: [fixed],
                    candidateContacts: contacts.filter { $0.identifier != fixed.identifier },
                    requiredContactCount: 2,
                    movementTolerance: 0.045,
                    startedAt: nil,
                    deadline: nil,
                    thresholds: .default,
                    rejectionSequence: 0
                )
            )
        }

        model.apply(snapshot(timestamp: 1, contacts: [fixed], phase: .armed))
        model.recordRecognized(.tipTapLeftOneFixed, deviceID: 1, at: 1)
        model.apply(snapshot(timestamp: 2, contacts: [fixed], phase: .armed))

        XCTAssertEqual(model.selectedRecognizedGesture, .tipTapLeftOneFixed)
        XCTAssertEqual(
            TrackpadGestureTestingStatusPresentationResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture
            ),
            .status(.recognized(.tipTapLeftOneFixed))
        )

        model.recordRecognized(.tipTapRightOneFixed, deviceID: 1, at: 2.1)
        model.apply(snapshot(timestamp: 2.2, contacts: [fixed], phase: .armed))
        XCTAssertEqual(model.selectedRecognizedGesture, .tipTapRightOneFixed)

        let added = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        model.apply(snapshot(timestamp: 3, contacts: [fixed, added], phase: .candidate))
        XCTAssertNil(model.selectedRecognizedGesture)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture
            ),
            .phase(.candidate, gesture: .tipTapLeftOneFixed)
        )
    }

    func testTestAllCommittedTipTapReconcilesCoalescedReleaseBeforeIdleFrames() throws {
        let model = TrackpadGestureTestingModel()
        model.begin(.allGestures)
        var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        let added = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        let nextAdded = TrackpadContactSnapshot(identifier: 3, x: 0.1, y: 0.5)

        let candidate = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [fixed, added],
            recognized: [],
            recognition: nil
        )
        let displayedCandidate = try XCTUnwrap(
            coalescer.offer(candidate, at: 0).snapshot
        ).preparingForDisplay(mode: .allGestures)
        model.apply(displayedCandidate)

        let release = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1.01,
            contacts: [fixed],
            recognized: [.tipTapLeftOneFixed],
            recognition: nil
        )
        XCTAssertNil(coalescer.offer(release, at: 0.01).snapshot)

        // Exact native-click correlation commits while the release remains queued.
        model.recordRecognized(.tipTapLeftOneFixed, deviceID: 1, at: release.timestamp)

        let displayedRelease = try XCTUnwrap(
            coalescer.takePending(deviceID: 1, at: 1 / 30).snapshot
        ).preparingForDisplay(mode: .allGestures)
        model.apply(displayedRelease)
        XCTAssertEqual(model.selectedRecognizedGesture, .tipTapLeftOneFixed)
        XCTAssertNil(model.selectedContactPatternGesture)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture,
                retainedContactPattern: model.selectedContactPatternGesture
            ),
            .recognized(.tipTapLeftOneFixed)
        )

        let idle = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1.02,
            contacts: [fixed],
            recognized: [],
            recognition: nil
        )
        let displayedIdle = try XCTUnwrap(
            coalescer.offer(idle, at: 0.08).snapshot
        ).preparingForDisplay(mode: .allGestures)
        model.apply(displayedIdle)
        XCTAssertEqual(model.selectedRecognizedGesture, .tipTapLeftOneFixed)

        let nextEpisode = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1.03,
            contacts: [fixed, nextAdded],
            recognized: [],
            recognition: nil
        )
        let displayedNextEpisode = try XCTUnwrap(
            coalescer.offer(nextEpisode, at: 0.12).snapshot
        ).preparingForDisplay(mode: .allGestures)
        model.apply(displayedNextEpisode)
        XCTAssertNil(model.selectedRecognizedGesture)
    }

    func testUncommittedTipTapContactPatternRemainsVisibleUntilNextAttempt() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.tipTapLeftOneFixed))
        let fixed = TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)
        let release = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [fixed],
            recognized: [.tipTapLeftOneFixed],
            recognition: nil
        ).preparingForDisplay(mode: .practice(.tipTapLeftOneFixed))

        model.apply(release)
        XCTAssertEqual(model.selectedContactPatternGesture, .tipTapLeftOneFixed)
        XCTAssertNil(model.selectedRecognizedGesture)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture,
                retainedContactPattern: model.selectedContactPatternGesture
            ),
            .contactPatternDetected(.tipTapLeftOneFixed)
        )

        model.apply(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1.01,
            contacts: [fixed],
            recognized: [],
            recognition: nil
        ))
        XCTAssertEqual(model.selectedContactPatternGesture, .tipTapLeftOneFixed)

        model.apply(TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1.02,
            contacts: [fixed, .init(identifier: 2, x: 0.1, y: 0.5)],
            recognized: [],
            recognition: nil
        ))
        XCTAssertNil(model.selectedContactPatternGesture)
    }

    func testTestAllCommittedTapAndDoubleTapReconcileCoalescedReleaseUntilNextAttempt() throws {
        for gesture in [TrackpadGesture.threeFingerTap, .threeFingerDoubleTap] {
            let model = TrackpadGestureTestingModel()
            model.begin(.allGestures)
            var coalescer = TrackpadGestureSnapshotCoalescer(maximumFramesPerSecond: 30)
            let contacts = [
                TrackpadContactSnapshot(identifier: 1, x: 0.3, y: 0.5),
                TrackpadContactSnapshot(identifier: 2, x: 0.5, y: 0.5),
                TrackpadContactSnapshot(identifier: 3, x: 0.7, y: 0.5),
            ]
            let down = TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: 1,
                contacts: contacts,
                recognized: [],
                recognition: nil
            )
            model.apply(try XCTUnwrap(
                coalescer.offer(down, at: 0).snapshot
            ).preparingForDisplay(mode: .allGestures))

            let release = TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: 1.01,
                contacts: [],
                recognized: [gesture],
                recognition: nil
            )
            XCTAssertNil(coalescer.offer(release, at: 0.01).snapshot)
            model.recordRecognized(gesture, deviceID: 1, at: release.timestamp)
            model.apply(try XCTUnwrap(
                coalescer.takePending(deviceID: 1, at: 1 / 30).snapshot
            ).preparingForDisplay(mode: .allGestures))

            let idle = TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: 1.02,
                contacts: [],
                recognized: [],
                recognition: nil
            )
            model.apply(try XCTUnwrap(
                coalescer.offer(idle, at: 0.08).snapshot
            ).preparingForDisplay(mode: .allGestures))
            XCTAssertEqual(model.selectedRecognizedGesture, gesture)

            let nextAttempt = TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: 1.03,
                contacts: contacts,
                recognized: [],
                recognition: nil
            )
            model.apply(try XCTUnwrap(
                coalescer.offer(nextAttempt, at: 0.12).snapshot
            ).preparingForDisplay(mode: .allGestures))
            XCTAssertNil(model.selectedRecognizedGesture)
        }
    }

    func testCommittedPhysicalClickSuccessSurvivesUntilContactsChange() {
        let model = TrackpadGestureTestingModel()
        model.begin(.practice(.threeFingerClick))
        let contacts = [
            TrackpadContactSnapshot(identifier: 1, x: 0.3, y: 0.5),
            TrackpadContactSnapshot(identifier: 2, x: 0.5, y: 0.5),
            TrackpadContactSnapshot(identifier: 3, x: 0.7, y: 0.5),
        ]
        func snapshot(
            timestamp: TimeInterval,
            contacts: [TrackpadContactSnapshot]
        ) -> TrackpadGestureTestSnapshot {
            TrackpadGestureTestSnapshot(
                deviceID: 1,
                descriptor: nil,
                timestamp: timestamp,
                contacts: contacts,
                recognized: [],
                recognition: TrackpadGestureRecognitionSnapshot(
                    gesture: .threeFingerClick,
                    phase: .physicalClick,
                    anchorContacts: [],
                    candidateContacts: [],
                    requiredContactCount: 3,
                    movementTolerance: 0,
                    startedAt: nil,
                    deadline: nil,
                    thresholds: .default,
                    rejectionSequence: 0
                )
            )
        }

        model.apply(snapshot(timestamp: 1, contacts: contacts))
        model.recordRecognized(.threeFingerClick, deviceID: 1, at: 1)
        model.apply(snapshot(timestamp: 2, contacts: contacts))
        XCTAssertEqual(model.selectedRecognizedGesture, .threeFingerClick)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture
            ),
            .recognized(.threeFingerClick)
        )

        model.apply(snapshot(timestamp: 3, contacts: []))
        XCTAssertNil(model.selectedRecognizedGesture)
        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: model.selectedSnapshot,
                retainedRecognition: model.selectedRecognizedGesture
            ),
            .phase(.physicalClick, gesture: .threeFingerClick)
        )
    }

    func testWaitingForSecondTapOverridesIdleRetainedSuccess() {
        let recognition = TrackpadGestureRecognitionSnapshot(
            gesture: .threeFingerDoubleTap,
            phase: .waitingForSecondTap,
            anchorContacts: [],
            candidateContacts: [],
            requiredContactCount: 3,
            movementTolerance: 0.035,
            startedAt: 1,
            deadline: 1.32,
            thresholds: .default,
            rejectionSequence: 0
        )
        let waiting = TrackpadGestureTestSnapshot(
            deviceID: 1,
            descriptor: nil,
            timestamp: 1,
            contacts: [],
            recognized: [],
            recognition: recognition
        )

        XCTAssertEqual(
            TrackpadGestureTestingStatusResolver.resolve(
                snapshot: waiting,
                retainedRecognition: .threeFingerTap
            ),
            .phase(.waitingForSecondTap, gesture: .threeFingerDoubleTap)
        )
    }

    private func snapshot(
        deviceID: UInt64,
        timestamp: TimeInterval,
        contacts: [TrackpadContactSnapshot]
    ) -> TrackpadGestureTestSnapshot {
        TrackpadGestureTestSnapshot(
            deviceID: deviceID,
            descriptor: nil,
            timestamp: timestamp,
            contacts: contacts,
            recognized: [],
            recognition: nil
        )
    }
}

private final class LockedTestingEmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TrackpadGestureTestSnapshotEmission] = []

    var values: [TrackpadGestureTestSnapshotEmission] {
        lock.withLock { storage }
    }

    func append(_ emission: TrackpadGestureTestSnapshotEmission) {
        lock.withLock { storage.append(emission) }
    }
}
