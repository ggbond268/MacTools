import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import MacToolsPluginKit

final class KeyboardKeyTapTests: XCTestCase {
    func testModifierFormatterDistinguishesEveryLeftAndRightKey() {
        let pairs: [(left: Int, right: Int, symbol: String)] = [
            (kVK_Command, kVK_RightCommand, "⌘"),
            (kVK_Shift, kVK_RightShift, "⇧"),
            (kVK_Option, kVK_RightOption, "⌥"),
            (kVK_Control, kVK_RightControl, "⌃"),
        ]

        for pair in pairs {
            let left = KeyboardKeyTapFormatter.displayString(
                for: KeyboardKeyTap(keyCode: UInt16(pair.left))
            )
            let right = KeyboardKeyTapFormatter.displayString(
                for: KeyboardKeyTap(keyCode: UInt16(pair.right))
            )
            XCTAssertTrue(left.contains(pair.symbol))
            XCTAssertTrue(right.contains(pair.symbol))
            XCTAssertNotEqual(left, right)
        }
    }

    func testRightCommandTapProducesSideSpecificFlagsChangedPair() throws {
        let keyTap = KeyboardKeyTap(keyCode: UInt16(kVK_RightCommand))
        let events = try XCTUnwrap(
            KeyboardKeyTapEventPoster.makeEvents(for: keyTap, ambientFlags: [])
        )

        XCTAssertEqual(events.down.type, .flagsChanged)
        XCTAssertEqual(events.up.type, .flagsChanged)
        XCTAssertEqual(events.down.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_RightCommand))
        XCTAssertEqual(events.up.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_RightCommand))
        XCTAssertTrue(events.down.flags.contains(.maskCommand))
        XCTAssertFalse(events.up.flags.contains(.maskCommand))
        XCTAssertGreaterThan(events.down.timestamp, 0)
        XCTAssertGreaterThan(events.up.timestamp, events.down.timestamp)
        XCTAssertTrue(MacToolsSyntheticInputEvent.isMarked(events.down))
        XCTAssertTrue(MacToolsSyntheticInputEvent.isMarked(events.up))
    }

    func testEveryLeftAndRightModifierKeepsItsVirtualKeyCode() throws {
        let pairs: [(left: Int, right: Int, flag: CGEventFlags)] = [
            (kVK_Command, kVK_RightCommand, .maskCommand),
            (kVK_Shift, kVK_RightShift, .maskShift),
            (kVK_Option, kVK_RightOption, .maskAlternate),
            (kVK_Control, kVK_RightControl, .maskControl),
        ]

        for pair in pairs {
            for keyCode in [pair.left, pair.right] {
                let events = try XCTUnwrap(KeyboardKeyTapEventPoster.makeEvents(
                    for: KeyboardKeyTap(keyCode: UInt16(keyCode)),
                    ambientFlags: []
                ))
                XCTAssertEqual(events.down.type, .flagsChanged)
                XCTAssertEqual(events.up.type, .flagsChanged)
                XCTAssertEqual(
                    events.down.getIntegerValueField(.keyboardEventKeycode),
                    Int64(keyCode)
                )
                XCTAssertEqual(
                    events.up.getIntegerValueField(.keyboardEventKeycode),
                    Int64(keyCode)
                )
                XCTAssertTrue(events.down.flags.contains(pair.flag))
                XCTAssertFalse(events.up.flags.contains(pair.flag))
            }
        }
    }

    func testEveryLeftAndRightModifierPreservesDistinctDeviceFlags() throws {
        let pairs: [(left: Int, right: Int)] = [
            (kVK_Command, kVK_RightCommand),
            (kVK_Shift, kVK_RightShift),
            (kVK_Option, kVK_RightOption),
            (kVK_Control, kVK_RightControl),
        ]

        for pair in pairs {
            let left = try XCTUnwrap(KeyboardKeyTapEventPoster.makeEvents(
                for: KeyboardKeyTap(keyCode: UInt16(pair.left)),
                ambientFlags: []
            ))
            let right = try XCTUnwrap(KeyboardKeyTapEventPoster.makeEvents(
                for: KeyboardKeyTap(keyCode: UInt16(pair.right)),
                ambientFlags: []
            ))

            XCTAssertNotEqual(left.down.flags.rawValue, right.down.flags.rawValue)
            XCTAssertTrue(KeyboardKeyTapEventTransition.isModifierPress(
                keyCode: UInt16(pair.left),
                flags: left.down.flags
            ))
            XCTAssertTrue(KeyboardKeyTapEventTransition.isModifierPress(
                keyCode: UInt16(pair.right),
                flags: right.down.flags
            ))
        }
    }

    func testModifierTransitionRejectsReleaseEvenWhenOppositeSideRemainsHeld() throws {
        let pairs: [(keyCode: Int, aggregateFlag: CGEventFlags)] = [
            (kVK_RightCommand, .maskCommand),
            (kVK_RightShift, .maskShift),
            (kVK_RightOption, .maskAlternate),
            (kVK_RightControl, .maskControl),
        ]

        for pair in pairs {
            let release = try XCTUnwrap(CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(pair.keyCode),
                keyDown: false
            ))
            release.flags.formUnion(pair.aggregateFlag)

            XCTAssertFalse(KeyboardKeyTapEventTransition.isModifierPress(
                keyCode: UInt16(pair.keyCode),
                flags: release.flags
            ))
        }
    }

    func testModifierTapPreservesAmbientPhysicalModifiersOnRelease() throws {
        let events = try XCTUnwrap(KeyboardKeyTapEventPoster.makeEvents(
            for: KeyboardKeyTap(keyCode: UInt16(kVK_RightOption)),
            ambientFlags: [.maskCommand, .maskShift]
        ))

        XCTAssertTrue(events.down.flags.contains(.maskAlternate))
        XCTAssertTrue(events.down.flags.contains(.maskCommand))
        XCTAssertTrue(events.down.flags.contains(.maskShift))
        XCTAssertFalse(events.up.flags.contains(.maskAlternate))
        XCTAssertTrue(events.up.flags.contains(.maskCommand))
        XCTAssertTrue(events.up.flags.contains(.maskShift))
    }

    func testOrdinarySingleKeyTapAllowsNoShortcutModifiers() throws {
        let events = try XCTUnwrap(KeyboardKeyTapEventPoster.makeEvents(
            for: KeyboardKeyTap(keyCode: UInt16(kVK_ANSI_A)),
            ambientFlags: []
        ))

        XCTAssertEqual(events.down.type, .keyDown)
        XCTAssertEqual(events.up.type, .keyUp)
        XCTAssertEqual(events.down.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_A))
        XCTAssertTrue(events.down.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty)
        XCTAssertTrue(events.up.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty)
    }

    func testKeyTapRoundTripsThroughCodable() throws {
        let keyTap = KeyboardKeyTap(keyCode: UInt16(kVK_RightControl))
        let data = try JSONEncoder().encode(keyTap)

        XCTAssertEqual(try JSONDecoder().decode(KeyboardKeyTap.self, from: data), keyTap)
    }

    func testUnsupportedKeyCodesAreNotPosted() {
        let capsLock = KeyboardKeyTap(keyCode: UInt16(kVK_CapsLock))
        let reserved = KeyboardKeyTap(keyCode: 0x42)
        let outOfRange = KeyboardKeyTap(keyCode: .max)

        XCTAssertFalse(capsLock.isSupported)
        XCTAssertFalse(reserved.isSupported)
        XCTAssertFalse(outOfRange.isSupported)
        XCTAssertNil(KeyboardKeyTapEventPoster.makeEvents(for: capsLock, ambientFlags: []))
        XCTAssertNil(KeyboardKeyTapEventPoster.makeEvents(for: reserved, ambientFlags: []))
        XCTAssertNil(KeyboardKeyTapEventPoster.makeEvents(for: outOfRange, ambientFlags: []))
    }

    func testSupportedKeyPolicyIncludesInternationalKeypadAndFunctionKeys() {
        let supportedKeyCodes = [
            kVK_ISO_Section,
            kVK_JIS_Kana,
            kVK_ANSI_KeypadEnter,
            kVK_F20,
        ]

        for keyCode in supportedKeyCodes {
            XCTAssertTrue(KeyboardKeyTap(keyCode: UInt16(keyCode)).isSupported)
        }

        for keyCode in [kVK_VolumeUp, kVK_VolumeDown, kVK_Mute] {
            XCTAssertFalse(KeyboardKeyTap(keyCode: UInt16(keyCode)).isSupported)
        }
    }

    func testSyntheticMarkerRecognizesMixedVersionPluginEvents() throws {
        XCTAssertEqual(MacToolsSyntheticInputEvent.marker, 0x4D_54_49_52)
        XCTAssertEqual(
            MacToolsSyntheticInputEvent.legacyTrackpadGesturesMarker,
            0x4D_54_4B_45_59_42_4F_41
        )
        XCTAssertEqual(
            MacToolsSyntheticInputEvent.supersededSharedMarker,
            0x4D_54_53_59_4E_54_48_45
        )
        let acceptedMarkers = [
            MacToolsSyntheticInputEvent.marker,
            MacToolsSyntheticInputEvent.legacyTrackpadGesturesMarker,
            MacToolsSyntheticInputEvent.supersededSharedMarker,
        ]

        for marker in acceptedMarkers {
            let event = try XCTUnwrap(CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_A),
                keyDown: true
            ))
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            XCTAssertTrue(MacToolsSyntheticInputEvent.isMarked(event))
        }
    }

    @MainActor
    func testKeyTapFallbackStringsFollowRuntimeLanguage() {
        let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
        let originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        defer {
            if let originalPreference {
                UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
            PluginRuntimeLocalization.source.setPreference(originalPreference)
        }

        PluginRuntimeLocalization.source.setPreference("ar")

        XCTAssertEqual(
            PluginKitLocalization.keyboardKeyTapPickerHelp,
            "اختر المفتاح المراد إرساله من القائمة."
        )
        XCTAssertEqual(PluginKitLocalization.keyboardKeyTapUnset, "غير محدد")
        XCTAssertEqual(
            PluginKitLocalization.keyboardKeyTapUnsupportedHelp,
            "مفتاح Caps Lock ومفاتيح الوسائط غير مدعومة."
        )
    }
}
