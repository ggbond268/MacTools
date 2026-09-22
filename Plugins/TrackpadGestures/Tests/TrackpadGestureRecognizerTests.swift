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
