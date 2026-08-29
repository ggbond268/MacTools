import XCTest
import MacToolsPluginKit
@testable import TrackpadGesturesPlugin

final class TrackpadGestureRecognizerTests: XCTestCase {
    func testPhysicalClickGesturesRequireNativeClickEvents() {
        var engine = TrackpadGestureEngine(gestures: [.twoFingerClick, .threeFingerClick])

        _ = engine.process(frame(time: 0, contacts: []))
        XCTAssertTrue(engine.process(frame(
            time: 0.01,
            contacts: Array(threeContacts.prefix(2))
        )).recognized.isEmpty)
        XCTAssertTrue(engine.process(frame(time: 0.08, contacts: [])).recognized.isEmpty)
        XCTAssertTrue(engine.process(frame(time: 0.40, contacts: threeContacts)).recognized.isEmpty)
        XCTAssertTrue(engine.process(frame(time: 0.48, contacts: [])).recognized.isEmpty)
    }

    func testTipTapClassifiesLeftAndRightAndTriggersAfterTapRelease() {
        var left = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        XCTAssertFalse(left.process(frame(time: 0, contacts: [])))
        XCTAssertFalse(left.process(frame(time: 0.01, contacts: [(1, 0.55, 0.5)])))
        XCTAssertFalse(left.process(frame(time: 0.09, contacts: [(1, 0.55, 0.5)])))
        XCTAssertFalse(left.process(frame(time: 0.10, contacts: [(1, 0.55, 0.5), (2, 0.15, 0.5)])))
        XCTAssertTrue(left.process(frame(time: 0.15, contacts: [(1, 0.55, 0.5)])))

        var right = TipTapRecognizer(fixedFingerCount: 1, region: .right)
        XCTAssertFalse(right.process(frame(time: 0, contacts: [])))
        XCTAssertFalse(right.process(frame(time: 0.01, contacts: [(1, 0.45, 0.5)])))
        XCTAssertFalse(right.process(frame(time: 0.09, contacts: [(1, 0.45, 0.5)])))
        XCTAssertFalse(right.process(frame(time: 0.10, contacts: [(1, 0.45, 0.5), (2, 0.85, 0.5)])))
        XCTAssertTrue(right.process(frame(time: 0.15, contacts: [(1, 0.45, 0.5)])))
    }

    func testTipTapRecognizesRepeatedTapsForEveryVariantWhileFixedFingersRemainDown() {
        let variants: [(
            fixedFingerCount: Int,
            region: TipTapRegion,
            fixedContacts: [(Int, Double, Double)],
            tapX: Double
        )] = [
            (1, .left, [(1, 0.5, 0.5)], 0.1),
            (1, .right, [(1, 0.5, 0.5)], 0.9),
            (2, .left, [(1, 0.3, 0.5), (2, 0.7, 0.5)], 0.1),
            (2, .middle, [(1, 0.3, 0.5), (2, 0.7, 0.5)], 0.5),
            (2, .right, [(1, 0.3, 0.5), (2, 0.7, 0.5)], 0.9),
        ]

        for variant in variants {
            var recognizer = TipTapRecognizer(
                fixedFingerCount: variant.fixedFingerCount,
                region: variant.region
            )
            _ = recognizer.process(frame(time: 0, contacts: []))
            _ = recognizer.process(frame(time: 0.01, contacts: variant.fixedContacts))
            _ = recognizer.process(frame(time: 0.09, contacts: variant.fixedContacts))

            for tapIndex in 0..<3 {
                let tappingContact = (
                    10 + tapIndex,
                    variant.tapX,
                    0.5
                )
                let downTime = 0.10 + Double(tapIndex) * 0.07
                XCTAssertFalse(recognizer.process(frame(
                    time: downTime,
                    contacts: variant.fixedContacts + [tappingContact]
                )))
                XCTAssertFalse(recognizer.process(frame(
                    time: downTime + 0.02,
                    contacts: variant.fixedContacts + [tappingContact]
                )))
                XCTAssertTrue(recognizer.process(frame(
                    time: downTime + 0.04,
                    contacts: variant.fixedContacts
                )), "expected repeated recognition for \(variant.fixedFingerCount)-finger \(variant.region)")
            }
        }
    }

    func testTipTapWrongRegionDoesNotEndEstablishedFixedFingerSession() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.09, contacts: [(1, 0.5, 0.5)]))

        XCTAssertFalse(recognizer.process(frame(time: 0.10, contacts: [
            (1, 0.5, 0.5), (2, 0.9, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.14, contacts: [(1, 0.5, 0.5)])))
        XCTAssertFalse(recognizer.process(frame(time: 0.16, contacts: [
            (1, 0.5, 0.5), (3, 0.1, 0.5),
        ])))
        XCTAssertTrue(recognizer.process(frame(time: 0.20, contacts: [(1, 0.5, 0.5)])))
    }

    func testTipTapIgnoredContactCannotMoveFromSiblingRegionIntoTargetRegion() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixedContact = [(1, 0.5, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContact))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContact))

        XCTAssertFalse(recognizer.process(frame(time: 0.10, contacts: fixedContact + [
            (2, 0.9, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.13, contacts: fixedContact + [
            (2, 0.1, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.16, contacts: fixedContact)))
        _ = recognizer.process(frame(time: 0.18, contacts: fixedContact + [(3, 0.1, 0.5)]))
        XCTAssertFalse(recognizer.process(frame(time: 0.22, contacts: fixedContact)))

        _ = recognizer.process(frame(time: 0.24, contacts: []))
        _ = recognizer.process(frame(time: 0.50, contacts: [(4, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.58, contacts: [(4, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.59, contacts: [
            (4, 0.5, 0.5), (5, 0.1, 0.5),
        ]))
        XCTAssertTrue(recognizer.process(frame(time: 0.63, contacts: [(4, 0.5, 0.5)])))
    }

    func testTipTapIgnoredContactCannotMoveFromAmbiguousPlacementIntoTargetRegion() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixedContact = [(1, 0.5, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContact))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContact))

        XCTAssertFalse(recognizer.process(frame(time: 0.10, contacts: fixedContact + [
            (2, 0.48, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.13, contacts: fixedContact + [
            (2, 0.45, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.16, contacts: fixedContact)))
        _ = recognizer.process(frame(time: 0.18, contacts: fixedContact + [(3, 0.1, 0.5)]))
        XCTAssertTrue(recognizer.process(frame(time: 0.22, contacts: fixedContact)))
    }

    func testTipTapIgnoredContactCannotBecomeCandidateAfterMaximumTapDuration() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixedContact = [(1, 0.5, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContact))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContact))

        XCTAssertFalse(recognizer.process(frame(time: 0.10, contacts: fixedContact + [
            (2, 0.9, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.40, contacts: fixedContact + [
            (2, 0.1, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.44, contacts: fixedContact)))
        _ = recognizer.process(frame(time: 0.46, contacts: fixedContact + [(3, 0.1, 0.5)]))
        XCTAssertFalse(recognizer.process(frame(time: 0.50, contacts: fixedContact)))
    }

    func testTipTapTooBriefIgnoredContactCancelsUntilAllContactsReset() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixedContact = [(1, 0.5, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContact))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContact))

        _ = recognizer.process(frame(time: 0.10, contacts: fixedContact + [(2, 0.9, 0.5)]))
        XCTAssertFalse(recognizer.process(frame(time: 0.11, contacts: fixedContact)))
        _ = recognizer.process(frame(time: 0.13, contacts: fixedContact + [(3, 0.1, 0.5)]))
        XCTAssertFalse(recognizer.process(frame(time: 0.17, contacts: fixedContact)))

        _ = recognizer.process(frame(time: 0.20, contacts: []))
        _ = recognizer.process(frame(time: 0.50, contacts: [(4, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.58, contacts: [(4, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.59, contacts: [
            (4, 0.5, 0.5), (5, 0.1, 0.5),
        ]))
        XCTAssertTrue(recognizer.process(frame(time: 0.63, contacts: [(4, 0.5, 0.5)])))
    }

    func testTipTapFullReleaseRearmsNewSessionWithoutRedundantZeroFrame() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        let fixedContact = [(1, 0.5, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContact))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContact))
        _ = recognizer.process(frame(time: 0.10, contacts: fixedContact + [(2, 0.1, 0.5)]))
        XCTAssertTrue(recognizer.process(frame(time: 0.14, contacts: fixedContact)))

        XCTAssertFalse(recognizer.process(frame(time: 0.16, contacts: [])))
        _ = recognizer.process(frame(time: 0.50, contacts: [(5, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.58, contacts: [(5, 0.5, 0.5)]))
        _ = recognizer.process(frame(time: 0.59, contacts: [
            (5, 0.5, 0.5), (6, 0.1, 0.5),
        ]))
        XCTAssertTrue(recognizer.process(frame(time: 0.63, contacts: [(5, 0.5, 0.5)])))
    }

    func testTipTapRejectsWrongRegionFixedFingerMovementAndExtraFinger() {
        var wrongRegion = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = wrongRegion.process(frame(time: 0, contacts: []))
        _ = wrongRegion.process(frame(time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = wrongRegion.process(frame(time: 0.09, contacts: [(1, 0.5, 0.5)]))
        _ = wrongRegion.process(frame(time: 0.10, contacts: [(1, 0.5, 0.5), (2, 0.9, 0.5)]))
        XCTAssertFalse(wrongRegion.process(frame(time: 0.14, contacts: [(1, 0.5, 0.5)])))

        var moved = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = moved.process(frame(time: 0, contacts: []))
        _ = moved.process(frame(time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = moved.process(frame(time: 0.09, contacts: [(1, 0.5, 0.5)]))
        _ = moved.process(frame(time: 0.10, contacts: [(1, 0.6, 0.5), (2, 0.1, 0.5)]))
        XCTAssertFalse(moved.process(frame(time: 0.14, contacts: [(1, 0.6, 0.5)])))

        var extra = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = extra.process(frame(time: 0, contacts: []))
        _ = extra.process(frame(time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = extra.process(frame(time: 0.09, contacts: [(1, 0.5, 0.5)]))
        _ = extra.process(frame(time: 0.10, contacts: [(1, 0.5, 0.5), (2, 0.1, 0.5), (3, 0.2, 0.5)]))
        XCTAssertFalse(extra.process(frame(time: 0.14, contacts: [(1, 0.5, 0.5)])))
    }

    func testTipTapRejectsExcessiveTapDurationAndTravel() {
        var duration = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = duration.process(frame(time: 0, contacts: []))
        _ = duration.process(frame(time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = duration.process(frame(time: 0.09, contacts: [(1, 0.5, 0.5)]))
        _ = duration.process(frame(time: 0.10, contacts: [(1, 0.5, 0.5), (2, 0.1, 0.5)]))
        XCTAssertFalse(duration.process(frame(time: 0.40, contacts: [(1, 0.5, 0.5)])))

        var travel = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = travel.process(frame(time: 0, contacts: []))
        _ = travel.process(frame(time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = travel.process(frame(time: 0.09, contacts: [(1, 0.5, 0.5)]))
        _ = travel.process(frame(time: 0.10, contacts: [(1, 0.5, 0.5), (2, 0.1, 0.5)]))
        _ = travel.process(frame(time: 0.13, contacts: [(1, 0.5, 0.5), (2, 0.2, 0.5)]))
        XCTAssertFalse(travel.process(frame(time: 0.15, contacts: [(1, 0.5, 0.5)])))
    }

    func testTipTapAllowsSequentialFixedFingerAcquisition() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 2, region: .middle)
        _ = recognizer.process(frame(time: 0, contacts: []))
        XCTAssertFalse(recognizer.process(frame(time: 0.01, contacts: [(1, 0.3, 0.5)])))
        XCTAssertFalse(recognizer.process(frame(time: 0.04, contacts: [
            (1, 0.3, 0.5), (2, 0.7, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.12, contacts: [
            (1, 0.3, 0.5), (2, 0.7, 0.5),
        ])))
        XCTAssertFalse(recognizer.process(frame(time: 0.13, contacts: [
            (1, 0.3, 0.5), (2, 0.7, 0.5), (3, 0.5, 0.5),
        ])))
        XCTAssertTrue(recognizer.process(frame(time: 0.17, contacts: [
            (1, 0.3, 0.5), (2, 0.7, 0.5),
        ])))
    }

    func testTipTapClassificationIsRelativeToDisplacedFixedContacts() {
        var left = TipTapRecognizer(fixedFingerCount: 1, region: .left)
        _ = left.process(frame(time: 0, contacts: []))
        _ = left.process(frame(time: 0.01, contacts: [(1, 0.85, 0.5)]))
        _ = left.process(frame(time: 0.09, contacts: [(1, 0.85, 0.5)]))
        _ = left.process(frame(time: 0.10, contacts: [(1, 0.85, 0.5), (2, 0.65, 0.5)]))
        XCTAssertTrue(left.process(frame(time: 0.15, contacts: [(1, 0.85, 0.5)])))

        var right = TipTapRecognizer(fixedFingerCount: 1, region: .right)
        _ = right.process(frame(time: 0, contacts: []))
        _ = right.process(frame(time: 0.01, contacts: [(1, 0.15, 0.5)]))
        _ = right.process(frame(time: 0.09, contacts: [(1, 0.15, 0.5)]))
        _ = right.process(frame(time: 0.10, contacts: [(1, 0.15, 0.5), (2, 0.35, 0.5)]))
        XCTAssertTrue(right.process(frame(time: 0.15, contacts: [(1, 0.15, 0.5)])))

        var middle = TipTapRecognizer(fixedFingerCount: 2, region: .middle)
        _ = middle.process(frame(time: 0, contacts: []))
        _ = middle.process(frame(time: 0.01, contacts: [(1, 0.08, 0.5), (2, 0.42, 0.5)]))
        _ = middle.process(frame(time: 0.09, contacts: [(1, 0.08, 0.5), (2, 0.42, 0.5)]))
        _ = middle.process(frame(time: 0.10, contacts: [
            (1, 0.08, 0.5), (2, 0.42, 0.5), (3, 0.25, 0.5),
        ]))
        XCTAssertTrue(middle.process(frame(time: 0.15, contacts: [
            (1, 0.08, 0.5), (2, 0.42, 0.5),
        ])))
    }

    func testMiddleTipTapAdaptsToNaturalFixedFingerSpacing() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 2, region: .middle)
        let fixedContacts = [(1, 0.47, 0.5), (2, 0.53, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContacts))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContacts))
        _ = recognizer.process(frame(time: 0.10, contacts: fixedContacts + [(3, 0.50, 0.5)]))

        XCTAssertTrue(recognizer.process(frame(time: 0.15, contacts: fixedContacts)))
    }

    func testMiddleTipTapStillRejectsContactsNearFixedFingerEdges() {
        var recognizer = TipTapRecognizer(fixedFingerCount: 2, region: .middle)
        let fixedContacts = [(1, 0.47, 0.5), (2, 0.53, 0.5)]
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: fixedContacts))
        _ = recognizer.process(frame(time: 0.09, contacts: fixedContacts))
        _ = recognizer.process(frame(time: 0.10, contacts: fixedContacts + [(3, 0.475, 0.5)]))

        XCTAssertFalse(recognizer.process(frame(time: 0.15, contacts: fixedContacts)))
    }

    func testMiddleTipTapRejectsVerticallyAlignedFixedContacts() {
        for fixedContacts in [
            [(1, 0.50, 0.40), (2, 0.50, 0.60)],
            [(1, 0.49, 0.40), (2, 0.51, 0.60)],
        ] {
            var recognizer = TipTapRecognizer(fixedFingerCount: 2, region: .middle)
            _ = recognizer.process(frame(time: 0, contacts: []))
            _ = recognizer.process(frame(time: 0.01, contacts: fixedContacts))
            _ = recognizer.process(frame(time: 0.09, contacts: fixedContacts))
            _ = recognizer.process(frame(
                time: 0.10,
                contacts: fixedContacts + [(3, 0.50, 0.50)]
            ))

            XCTAssertFalse(recognizer.process(frame(time: 0.15, contacts: fixedContacts)))
        }
    }

    func testLateStaggeredThreeFingerTapOutsideTipTapRegionStillRecognizes() {
        var engine = TrackpadGestureEngine(gestures: [
            .tipTapMiddleTwoFixed,
            .threeFingerTap,
        ])
        let fixedContacts = [(1, 0.30, 0.5), (2, 0.70, 0.5)]
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: fixedContacts))
        _ = engine.process(frame(
            time: 0.09,
            contacts: fixedContacts + [(3, 0.90, 0.5)]
        ))

        XCTAssertEqual(
            engine.process(frame(time: 0.14, contacts: [])).recognized,
            [.threeFingerTap]
        )
    }

    func testMultiFingerTapAllowsStaggeredReleaseAndPreventsCooldownDuplicate() {
        var recognizer = MultiFingerTapRecognizer(fingerCount: 3)
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: threeContacts))
        _ = recognizer.process(frame(time: 0.06, contacts: Array(threeContacts.prefix(2))))
        XCTAssertTrue(recognizer.process(frame(time: 0.10, contacts: [])))

        _ = recognizer.process(frame(time: 0.11, contacts: []))
        _ = recognizer.process(frame(time: 0.20, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.24, contacts: [])))

        _ = recognizer.process(frame(time: 0.25, contacts: []))
        _ = recognizer.process(frame(time: 0.50, contacts: threeContacts))
        XCTAssertTrue(recognizer.process(frame(time: 0.56, contacts: [])))
    }

    func testMultiFingerTapAllowsSequentialAcquisitionForEverySupportedCount() {
        for fingerCount in 3...5 {
            var recognizer = MultiFingerTapRecognizer(fingerCount: fingerCount)
            _ = recognizer.process(frame(time: 0, contacts: []))
            for count in 1...fingerCount {
                XCTAssertFalse(recognizer.process(frame(
                    time: Double(count) * 0.015,
                    contacts: contacts(count: count)
                )))
            }
            XCTAssertTrue(recognizer.process(frame(time: 0.16, contacts: [])))
        }
    }

    func testMultiFingerTapRecognizesConsecutiveEpisodesWithoutRedundantZeroFrame() {
        for fingerCount in 3...5 {
            var recognizer = MultiFingerTapRecognizer(fingerCount: fingerCount)
            let activeContacts = contacts(count: fingerCount)

            _ = recognizer.process(frame(time: 0, contacts: []))
            _ = recognizer.process(frame(time: 0.01, contacts: activeContacts))
            XCTAssertTrue(recognizer.process(frame(time: 0.06, contacts: [])))

            // The successful release frame already established zero contacts. A new gesture may
            // begin after cooldown without relying on a second empty MultitouchSupport callback.
            XCTAssertFalse(recognizer.process(frame(time: 0.40, contacts: activeContacts)))
            XCTAssertTrue(recognizer.process(frame(time: 0.45, contacts: [])))
        }
    }

    func testMultiFingerDoubleTapRecognizesEverySupportedCount() {
        for fingerCount in 3...5 {
            var recognizer = MultiFingerDoubleTapRecognizer(fingerCount: fingerCount)
            let activeContacts = contacts(count: fingerCount)

            XCTAssertFalse(recognizer.process(frame(time: 0, contacts: [])))
            XCTAssertFalse(recognizer.process(frame(time: 0.01, contacts: activeContacts)))
            XCTAssertFalse(recognizer.process(frame(time: 0.07, contacts: [])))
            XCTAssertFalse(recognizer.process(frame(time: 0.17, contacts: activeContacts)))
            XCTAssertTrue(recognizer.process(frame(time: 0.23, contacts: [])))
        }
    }

    func testMultiFingerDoubleTapRejectsSlowSecondTapAndPairsItWithNextTap() {
        var recognizer = MultiFingerDoubleTapRecognizer(fingerCount: 3)

        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.07, contacts: [])))

        _ = recognizer.process(frame(time: 0.45, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.51, contacts: [])))

        _ = recognizer.process(frame(time: 0.61, contacts: threeContacts))
        XCTAssertTrue(recognizer.process(frame(time: 0.67, contacts: [])))
    }

    func testMultiFingerDoubleTapRejectsMovedEpisode() {
        var recognizer = MultiFingerDoubleTapRecognizer(fingerCount: 3)
        let movedContacts = threeContacts.map { contact in
            (contact.0, contact.1 + 0.08, contact.2)
        }

        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.07, contacts: [])))
        _ = recognizer.process(frame(time: 0.17, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.20, contacts: movedContacts)))
        XCTAssertFalse(recognizer.process(frame(time: 0.23, contacts: [])))

        _ = recognizer.process(frame(time: 0.28, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.34, contacts: [])))
        _ = recognizer.process(frame(time: 0.44, contacts: threeContacts))
        XCTAssertTrue(recognizer.process(frame(time: 0.50, contacts: [])))
    }

    func testLongTouchRecognizesOnceAndCancelsOnMovementOrFingerLoss() {
        var recognizer = LongTouchRecognizer(fingerCount: 3)
        _ = recognizer.process(frame(time: 0, contacts: []))
        _ = recognizer.process(frame(time: 0.01, contacts: threeContacts))
        XCTAssertFalse(recognizer.process(frame(time: 0.40, contacts: threeContacts)))
        XCTAssertTrue(recognizer.process(frame(time: 0.57, contacts: threeContacts)))
        XCTAssertFalse(recognizer.process(frame(time: 0.80, contacts: threeContacts)))

        var moved = LongTouchRecognizer(fingerCount: 3)
        _ = moved.process(frame(time: 0, contacts: []))
        _ = moved.process(frame(time: 0.01, contacts: threeContacts))
        let displaced = [(1, 0.2, 0.1), (2, 0.2, 0.1), (3, 0.3, 0.1)]
        XCTAssertFalse(moved.process(frame(time: 0.30, contacts: displaced)))
        XCTAssertFalse(moved.process(frame(time: 0.60, contacts: displaced)))

        var lostFinger = LongTouchRecognizer(fingerCount: 3)
        _ = lostFinger.process(frame(time: 0, contacts: []))
        _ = lostFinger.process(frame(time: 0.01, contacts: threeContacts))
        XCTAssertFalse(lostFinger.process(frame(time: 0.30, contacts: Array(threeContacts.prefix(2)))))
        XCTAssertFalse(lostFinger.process(frame(time: 0.60, contacts: threeContacts)))
    }

    func testLongTouchAllowsSequentialAcquisitionForEverySupportedCount() {
        for fingerCount in 3...5 {
            var recognizer = LongTouchRecognizer(fingerCount: fingerCount)
            _ = recognizer.process(frame(time: 0, contacts: []))
            for count in 1...fingerCount {
                XCTAssertFalse(recognizer.process(frame(
                    time: Double(count) * 0.015,
                    contacts: contacts(count: count)
                )))
            }
            XCTAssertTrue(recognizer.process(frame(time: 0.65, contacts: contacts(count: fingerCount))))
        }
    }

    func testEnginePrefersDoubleTapOverOverlappingSingleTapOnSecondRelease() {
        for fingerCount in 3...5 {
            let singleGesture = TrackpadGesture.fingerTap(count: fingerCount)
            let doubleGesture: TrackpadGesture = switch fingerCount {
            case 4: .fourFingerDoubleTap
            case 5: .fiveFingerDoubleTap
            default: .threeFingerDoubleTap
            }
            let activeContacts = contacts(count: fingerCount)
            var engine = TrackpadGestureEngine(gestures: [singleGesture, doubleGesture])

            _ = engine.process(frame(time: 0, contacts: []))
            _ = engine.process(frame(time: 0.01, contacts: activeContacts))
            XCTAssertEqual(
                engine.process(frame(time: 0.07, contacts: [])).recognized,
                [singleGesture]
            )
            // Start after the ordinary recognizer's cooldown so both recognizers accept the
            // second episode; the double tap must still be the sole result on release.
            _ = engine.process(frame(time: 0.36, contacts: activeContacts))
            XCTAssertEqual(
                engine.process(frame(time: 0.38, contacts: [])).recognized,
                [doubleGesture]
            )
        }
    }

    func testEngineKeepsRecognitionStateIsolatedPerDevice() {
        var engine = TrackpadGestureEngine(gestures: [.tipTapLeftOneFixed])
        _ = engine.process(frame(device: 1, time: 0, contacts: []))
        _ = engine.process(frame(device: 1, time: 0.01, contacts: [(1, 0.5, 0.5)]))
        _ = engine.process(frame(device: 1, time: 0.10, contacts: [(1, 0.5, 0.5)]))
        _ = engine.process(frame(device: 1, time: 0.11, contacts: [(1, 0.5, 0.5), (2, 0.1, 0.5)]))

        _ = engine.process(frame(device: 2, time: 0, contacts: []))
        _ = engine.process(frame(device: 2, time: 0.01, contacts: [(7, 0.5, 0.5)]))
        _ = engine.process(frame(device: 2, time: 0.10, contacts: [(7, 0.5, 0.5)]))
        _ = engine.process(frame(device: 2, time: 0.11, contacts: [(7, 0.5, 0.5), (8, 0.1, 0.5)]))
        let deviceTwo = engine.process(frame(device: 2, time: 0.16, contacts: [(7, 0.5, 0.5)]))
        let deviceOne = engine.process(frame(device: 1, time: 0.17, contacts: [(1, 0.5, 0.5)]))

        XCTAssertEqual(deviceTwo.recognized, [.tipTapLeftOneFixed])
        XCTAssertEqual(deviceOne.recognized, [.tipTapLeftOneFixed])
    }

    func testTypingSuppressionRequiresEveryContactToLiftBeforeTipTapRearms() {
        var engine = TrackpadGestureEngine(gestures: [.tipTapLeftOneFixed])
        let fixedContact = [(1, 0.5, 0.5)]

        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: fixedContact))
        _ = engine.process(frame(time: 0.09, contacts: fixedContact), suppressRecognition: true)

        _ = engine.process(frame(time: 0.60, contacts: fixedContact))
        _ = engine.process(frame(time: 0.61, contacts: fixedContact + [(2, 0.1, 0.5)]))
        let palmStillPresent = engine.process(frame(time: 0.66, contacts: fixedContact))
        XCTAssertTrue(palmStillPresent.recognized.isEmpty)

        _ = engine.process(frame(time: 0.70, contacts: []))
        _ = engine.process(frame(time: 1.0, contacts: fixedContact))
        _ = engine.process(frame(time: 1.09, contacts: fixedContact))
        _ = engine.process(frame(time: 1.10, contacts: fixedContact + [(3, 0.1, 0.5)]))
        let deliberateTipTap = engine.process(frame(time: 1.15, contacts: fixedContact))
        XCTAssertEqual(deliberateTipTap.recognized, [.tipTapLeftOneFixed])
    }

    func testTypingEventInvalidatesRecognitionEvenWithoutFrameDuringGracePeriod() {
        var engine = TrackpadGestureEngine(gestures: [.tipTapLeftOneFixed])
        let fixedContact = [(1, 0.5, 0.5)]
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: fixedContact))
        _ = engine.process(frame(time: 0.09, contacts: fixedContact))

        engine.beginSuppression()

        _ = engine.process(frame(time: 1.0, contacts: fixedContact))
        _ = engine.process(frame(time: 1.01, contacts: fixedContact + [(2, 0.1, 0.5)]))
        let staleRelease = engine.process(frame(time: 1.06, contacts: fixedContact))
        XCTAssertTrue(staleRelease.recognized.isEmpty)

        _ = engine.process(frame(time: 1.10, contacts: []))
        _ = engine.process(frame(time: 1.20, contacts: fixedContact))
        _ = engine.process(frame(time: 1.29, contacts: fixedContact))
        _ = engine.process(frame(time: 1.30, contacts: fixedContact + [(3, 0.1, 0.5)]))
        let deliberateRelease = engine.process(frame(time: 1.35, contacts: fixedContact))
        XCTAssertEqual(deliberateRelease.recognized, [.tipTapLeftOneFixed])
    }

    func testTypingSuppressionWaitsForEveryTrackpadToClearBeforeRearming() {
        var engine = TrackpadGestureEngine(gestures: [.threeFingerTap])
        _ = engine.process(frame(device: 1, time: 0, contacts: threeContacts), suppressRecognition: true)

        _ = engine.process(frame(device: 2, time: 0, contacts: []))
        _ = engine.process(frame(device: 2, time: 0.01, contacts: threeContacts))
        let blockedOtherTrackpad = engine.process(frame(device: 2, time: 0.08, contacts: []))
        XCTAssertTrue(blockedOtherTrackpad.recognized.isEmpty)

        _ = engine.process(frame(device: 1, time: 0.09, contacts: []))
        _ = engine.process(frame(device: 2, time: 0.10, contacts: threeContacts))
        let rearmedOtherTrackpad = engine.process(frame(device: 2, time: 0.17, contacts: []))

        XCTAssertEqual(rearmedOtherTrackpad.recognized, [.threeFingerTap])
    }

    func testInactiveTrackpadDoesNotBlockGlobalTypingReset() {
        var engine = TrackpadGestureEngine(gestures: [.threeFingerTap])
        _ = engine.process(frame(device: 2, time: 0, contacts: []))
        _ = engine.process(
            frame(device: 1, time: 0.01, contacts: threeContacts),
            suppressRecognition: true
        )
        _ = engine.process(frame(device: 1, time: 0.02, contacts: []))

        _ = engine.process(frame(device: 2, time: 0.10, contacts: threeContacts))
        let otherTrackpad = engine.process(frame(device: 2, time: 0.17, contacts: []))

        XCTAssertEqual(otherTrackpad.recognized, [.threeFingerTap])
    }

    func testEngineRecognizesTwoFixedTipTapAfterDeliberateFixedFingerHold() {
        var engine = TrackpadGestureEngine(gestures: [
            .tipTapMiddleTwoFixed,
            .threeFingerTap,
        ])
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: [(1, 0.25, 0.5), (2, 0.75, 0.5)]))
        _ = engine.process(frame(time: 0.10, contacts: [(1, 0.25, 0.5), (2, 0.75, 0.5)]))
        _ = engine.process(frame(time: 0.12, contacts: [
            (1, 0.25, 0.5), (2, 0.75, 0.5), (3, 0.5, 0.5),
        ]))

        let tipTapRelease = engine.process(frame(time: 0.17, contacts: [
            (1, 0.25, 0.5), (2, 0.75, 0.5),
        ]))
        let fixedRelease = engine.process(frame(time: 0.20, contacts: []))

        XCTAssertEqual(tipTapRelease.recognized, [.tipTapMiddleTwoFixed])
        XCTAssertTrue(fixedRelease.recognized.isEmpty)
    }

    func testEngineAlternatesTipTapRegionsWithoutLiftingFixedFinger() {
        var engine = TrackpadGestureEngine(gestures: [
            .tipTapLeftOneFixed,
            .tipTapRightOneFixed,
        ])
        let fixedContact = [(1, 0.5, 0.5)]
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: fixedContact))
        _ = engine.process(frame(time: 0.09, contacts: fixedContact))

        _ = engine.process(frame(time: 0.10, contacts: fixedContact + [(2, 0.1, 0.5)]))
        let firstLeft = engine.process(frame(time: 0.14, contacts: fixedContact))
        _ = engine.process(frame(time: 0.16, contacts: fixedContact + [(3, 0.9, 0.5)]))
        let right = engine.process(frame(time: 0.20, contacts: fixedContact))
        _ = engine.process(frame(time: 0.22, contacts: fixedContact + [(4, 0.1, 0.5)]))
        let secondLeft = engine.process(frame(time: 0.26, contacts: fixedContact))

        XCTAssertEqual(firstLeft.recognized, [.tipTapLeftOneFixed])
        XCTAssertEqual(right.recognized, [.tipTapRightOneFixed])
        XCTAssertEqual(secondLeft.recognized, [.tipTapLeftOneFixed])
    }

    func testEngineRepeatedTipTapContinuesToSuppressOverlappingThreeFingerTap() {
        var engine = TrackpadGestureEngine(gestures: [
            .tipTapMiddleTwoFixed,
            .threeFingerTap,
        ])
        let fixedContacts = [(1, 0.25, 0.5), (2, 0.75, 0.5)]
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: fixedContacts))
        _ = engine.process(frame(time: 0.10, contacts: fixedContacts))

        _ = engine.process(frame(time: 0.12, contacts: fixedContacts + [(3, 0.5, 0.5)]))
        let firstRelease = engine.process(frame(time: 0.16, contacts: fixedContacts))
        _ = engine.process(frame(time: 0.18, contacts: fixedContacts + [(4, 0.5, 0.5)]))
        let secondRelease = engine.process(frame(time: 0.22, contacts: fixedContacts))
        let allReleased = engine.process(frame(time: 0.24, contacts: []))

        XCTAssertEqual(firstRelease.recognized, [.tipTapMiddleTwoFixed])
        XCTAssertEqual(secondRelease.recognized, [.tipTapMiddleTwoFixed])
        XCTAssertTrue(allReleased.recognized.isEmpty)
    }

    func testEngineRejectsStaggeredOrdinaryTwoFingerTapAsTipTap() {
        var engine = TrackpadGestureEngine(gestures: [.tipTapLeftOneFixed])
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: [(1, 0.55, 0.5)]))
        let secondFingerDown = engine.process(frame(time: 0.05, contacts: [
            (1, 0.55, 0.5), (2, 0.15, 0.5),
        ]))
        let secondFingerUp = engine.process(frame(time: 0.10, contacts: [(1, 0.55, 0.5)]))
        let allReleased = engine.process(frame(time: 0.14, contacts: []))

        XCTAssertTrue(secondFingerDown.recognized.isEmpty)
        XCTAssertTrue(secondFingerUp.recognized.isEmpty)
        XCTAssertTrue(allReleased.recognized.isEmpty)
    }

    func testEnginePreservesStaggeredOrdinaryThreeFingerTap() {
        var engine = TrackpadGestureEngine(gestures: [
            .tipTapMiddleTwoFixed,
            .threeFingerTap,
        ])
        _ = engine.process(frame(time: 0, contacts: []))
        _ = engine.process(frame(time: 0.01, contacts: [
            (1, 0.25, 0.5), (2, 0.75, 0.5),
        ]))
        let thirdFingerDown = engine.process(frame(time: 0.05, contacts: [
            (1, 0.25, 0.5), (2, 0.75, 0.5), (3, 0.5, 0.5),
        ]))
        let thirdFingerUp = engine.process(frame(time: 0.10, contacts: [
            (1, 0.25, 0.5), (2, 0.75, 0.5),
        ]))
        let allReleased = engine.process(frame(time: 0.15, contacts: []))

        XCTAssertTrue(thirdFingerDown.recognized.isEmpty)
        XCTAssertTrue(thirdFingerUp.recognized.isEmpty)
        XCTAssertEqual(allReleased.recognized, [.threeFingerTap])
    }

    func testRecognitionGenerationInvalidatesEarlierDeliveryTokenSynchronously() {
        let generation = TrackpadGestureRecognitionGeneration()
        let first = generation.advance()
        XCTAssertTrue(generation.isCurrent(first))

        let second = generation.advance()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testRecognitionWorkerDeliversEveryRepeatedTipTap() {
        let recognized = TrackpadGestureRecorder()
        let worker = TrackpadGestureRecognitionWorker(
            generation: TrackpadGestureRecognitionGeneration(),
            onRecognized: { gesture, _, _ in recognized.append(gesture) }
        )
        let fixedContact = [(1, 0.5, 0.5)]

        worker.configure(gestures: [.tipTapLeftOneFixed], reset: true)
        worker.process(frame(time: 0, contacts: []))
        worker.process(frame(time: 0.01, contacts: fixedContact))
        worker.process(frame(time: 0.09, contacts: fixedContact))
        worker.process(frame(time: 0.10, contacts: fixedContact + [(2, 0.1, 0.5)]))
        worker.process(frame(time: 0.14, contacts: fixedContact))
        worker.process(frame(time: 0.16, contacts: fixedContact + [(3, 0.1, 0.5)]))
        worker.process(frame(time: 0.20, contacts: fixedContact))
        worker.waitUntilIdleForTests()

        XCTAssertEqual(recognized.values, [
            .tipTapLeftOneFixed,
            .tipTapLeftOneFixed,
        ])
    }

    func testStoppingTestModeOrdersConfigurationBeforeInFlightReleaseFrame() {
        let generation = TrackpadGestureRecognitionGeneration()
        let configurationGate = TrackpadGestureConfigurationSubmissionGate(pauseAtSubmission: 2)
        let recognized = TrackpadGestureRecorder()
        let worker = TrackpadGestureRecognitionWorker(
            generation: generation,
            beforeConfigurationEnqueue: { configurationGate.pauseIfNeeded() },
            onRecognized: { gesture, _, _ in recognized.append(gesture) }
        )

        worker.configure(gestures: Set(TrackpadGesture.allCases), reset: true)
        worker.process(frame(time: 0, contacts: []))
        worker.process(frame(time: 0.01, contacts: threeContacts))
        worker.waitUntilIdleForTests()

        let configurationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            worker.configure(gestures: [.threeFingerTap])
            configurationFinished.signal()
        }
        XCTAssertEqual(configurationGate.waitUntilPaused(), .success)

        let frameSubmissionFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            worker.process(self.frame(time: 0.10, contacts: []))
            frameSubmissionFinished.signal()
        }

        XCTAssertEqual(
            frameSubmissionFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "a frame must not acquire the new generation before its configuration is enqueued"
        )
        configurationGate.resume()
        XCTAssertEqual(configurationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(frameSubmissionFinished.wait(timeout: .now() + 1), .success)
        worker.waitUntilIdleForTests()

        XCTAssertTrue(recognized.values.isEmpty)
    }

    private var threeContacts: [(Int, Double, Double)] {
        [(1, 0.1, 0.1), (2, 0.2, 0.1), (3, 0.3, 0.1)]
    }

    private func contacts(count: Int) -> [(Int, Double, Double)] {
        (1...count).map { ($0, Double($0) * 0.1, 0.1) }
    }

    private func frame(
        device: UInt64 = 1,
        time: TimeInterval,
        contacts: [(Int, Double, Double)]
    ) -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: device,
            timestamp: time,
            contacts: contacts.map {
                TrackpadContactSnapshot(identifier: $0.0, x: $0.1, y: $0.2)
            }
        )
    }
}

private final class TrackpadGestureConfigurationSubmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let pauseAtSubmission: Int
    private var submissionCount = 0
    private let paused = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)

    init(pauseAtSubmission: Int) {
        self.pauseAtSubmission = pauseAtSubmission
    }

    func pauseIfNeeded() {
        let shouldPause = lock.withLock {
            submissionCount += 1
            return submissionCount == pauseAtSubmission
        }
        guard shouldPause else { return }
        paused.signal()
        continuation.wait()
    }

    func waitUntilPaused() -> DispatchTimeoutResult {
        paused.wait(timeout: .now() + 1)
    }

    func resume() {
        continuation.signal()
    }
}

private final class TrackpadGestureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [TrackpadGesture] = []

    var values: [TrackpadGesture] {
        lock.withLock { recordedValues }
    }

    func append(_ gesture: TrackpadGesture) {
        lock.withLock {
            recordedValues.append(gesture)
        }
    }
}
