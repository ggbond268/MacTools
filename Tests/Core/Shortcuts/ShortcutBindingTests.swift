import Carbon.HIToolbox
import XCTest
@testable import MacToolsPluginKit

final class ShortcutBindingTests: XCTestCase {
    func testF1ThroughF12AreValidWithoutModifiers() {
        let functionKeyCodes = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]

        for keyCode in functionKeyCodes {
            let binding = ShortcutBinding(keyCode: UInt16(keyCode), modifiers: [])

            XCTAssertTrue(binding.isValid, "Expected key code \(keyCode) to support modifierless recording")
        }
    }

    func testRegularKeyStillRequiresModifier() {
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])

        XCTAssertFalse(binding.isValid)
    }

    func testFunctionKeysOutsideF1ThroughF12StillRequireModifier() {
        let binding = ShortcutBinding(keyCode: UInt16(kVK_F13), modifiers: [])

        XCTAssertFalse(binding.isValid)
    }

    func testRecorderExplainsMissingModifiersForKeysThatRequireThem() {
        let plainLetter = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])
        let modifiedLetter = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command])
        let functionKey = ShortcutBinding(keyCode: UInt16(kVK_F1), modifiers: [])
        let extendedFunctionKey = ShortcutBinding(keyCode: UInt16(kVK_F13), modifiers: [])

        XCTAssertEqual(
            PluginShortcutRecorderValidation.missingModifierMessage(for: plainLetter),
            ShortcutValidationError.missingModifier.localizedDescription
        )
        XCTAssertNil(PluginShortcutRecorderValidation.missingModifierMessage(for: modifiedLetter))
        XCTAssertNil(PluginShortcutRecorderValidation.missingModifierMessage(for: functionKey))
        XCTAssertEqual(
            PluginShortcutRecorderValidation.missingModifierMessage(for: extendedFunctionKey),
            ShortcutValidationError.missingModifier.localizedDescription
        )
    }

    func testRecorderAccessibilityAnnouncesAssignmentAndRecordingState() {
        XCTAssertEqual(
            PluginShortcutRecorderAccessibility.value(
                displayText: "",
                placeholder: "Not set",
                isRecording: false
            ),
            "Not set"
        )
        XCTAssertEqual(
            PluginShortcutRecorderAccessibility.value(
                displayText: "⌘ + V",
                placeholder: "Not set",
                isRecording: false
            ),
            "⌘ + V"
        )
        XCTAssertEqual(
            PluginShortcutRecorderAccessibility.value(
                displayText: "⌘ + V",
                placeholder: "Not set",
                isRecording: true
            ),
            PluginKitLocalization.shortcutRecorderPreviewPlaceholder
        )
    }
}
