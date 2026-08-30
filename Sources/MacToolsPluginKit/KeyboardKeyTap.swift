import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One physical keyboard key pressed and released atomically.
///
/// Unlike ``ShortcutBinding``, a key tap is generated output rather than a
/// globally registered shortcut. It therefore permits unmodified keys and
/// modifier keys such as the left and right Command keys.
public struct KeyboardKeyTap: Codable, Hashable, Sendable {
    /// The largest virtual key code declared by Carbon for a supported keyboard key.
    public static let maximumSupportedKeyCode: UInt16 = 0x7E

    public let keyCode: UInt16

    public init(keyCode: UInt16) {
        self.keyCode = keyCode
    }

    /// Whether this key can currently be recorded and emitted by MacTools.
    ///
    /// Caps Lock is intentionally excluded until its persistent toggle state can
    /// be validated separately from momentary modifier-key presses. System media
    /// keys are excluded because macOS delivers them as system-defined events.
    public var isSupported: Bool {
        Self.isSupported(keyCode: keyCode)
    }

    public static func isSupported(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x00...0x33,
             0x35...0x38,
             0x3A...0x41,
             0x43,
             0x45,
             0x47,
             0x4B...0x4C,
             0x4E...0x6B,
             0x6D...0x6F,
             0x71...maximumSupportedKeyCode:
            true
        default:
            false
        }
    }
}

public enum KeyboardKeyTapFormatter {
    public static func displayString(for keyTap: KeyboardKeyTap?) -> String {
        guard let keyTap, keyTap.isSupported else {
            return PluginKitLocalization.keyboardKeyTapUnset
        }
        return keyDisplayName(for: keyTap.keyCode)
    }

    public static func keyDisplayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case UInt16(kVK_Command): return "⌘ · \(PluginKitLocalization.keyboardKeyLeft)"
        case UInt16(kVK_RightCommand): return "⌘ · \(PluginKitLocalization.keyboardKeyRight)"
        case UInt16(kVK_Shift): return "⇧ · \(PluginKitLocalization.keyboardKeyLeft)"
        case UInt16(kVK_RightShift): return "⇧ · \(PluginKitLocalization.keyboardKeyRight)"
        case UInt16(kVK_Option): return "⌥ · \(PluginKitLocalization.keyboardKeyLeft)"
        case UInt16(kVK_RightOption): return "⌥ · \(PluginKitLocalization.keyboardKeyRight)"
        case UInt16(kVK_Control): return "⌃ · \(PluginKitLocalization.keyboardKeyLeft)"
        case UInt16(kVK_RightControl): return "⌃ · \(PluginKitLocalization.keyboardKeyRight)"
        case UInt16(kVK_CapsLock): return "⇪"
        case 63: return "Fn"
        default: return ShortcutFormatter.keyDisplayName(for: keyCode)
        }
    }
}

/// Shared marker used by MacTools-generated input so input-consuming plugins
/// can pass it through instead of remapping it again.
public enum MacToolsSyntheticInputEvent {
    /// The legacy Input Remapping marker remains canonical so older installed
    /// versions of that input-consuming plugin also pass new generated events through.
    public static let marker: Int64 = 0x4D_54_49_52
    public static let legacyTrackpadGesturesMarker: Int64 = 0x4D_54_4B_45_59_42_4F_41
    public static let supersededSharedMarker: Int64 = 0x4D_54_53_59_4E_54_48_45

    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    public static func isMarked(_ event: CGEvent) -> Bool {
        switch event.getIntegerValueField(.eventSourceUserData) {
        case marker, legacyTrackpadGesturesMarker, supersededSharedMarker:
            true
        default:
            false
        }
    }
}

/// Classifies the press half of a modifier `flagsChanged` event while retaining
/// the distinct device flags used by left and right modifier keys.
public enum KeyboardKeyTapEventTransition {
    public static func isModifierPress(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard KeyboardKeyTap.isSupported(keyCode: keyCode),
              ShortcutKeyCode.isModifier(keyCode)
        else {
            return false
        }

        if keyCode == 63 {
            return flags.contains(.maskSecondaryFn)
        }

        guard let identityFlags = modifierIdentityFlags[keyCode] else { return false }
        return !flags.intersection(identityFlags).isEmpty
    }

    private static let sidedModifierKeyCodes: [UInt16] = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Control), UInt16(kVK_RightControl),
    ]

    /// Derive the device-dependent identity bits from CoreGraphics rather than
    /// duplicating private NX flag constants in PluginKit.
    private static let modifierIdentityFlags: [UInt16: CGEventFlags] = {
        var result: [UInt16: CGEventFlags] = [:]
        for keyCode in sidedModifierKeyCodes {
            guard let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: false
            ) else {
                continue
            }
            let changedFlags = down.flags.subtracting(up.flags)
            let identityFlags = changedFlags.subtracting(KeyboardKeyTapEventPoster.modifierFlags)
            if !identityFlags.isEmpty {
                result[keyCode] = identityFlags
            }
        }
        return result
    }()
}

public enum KeyboardKeyTapEventPoster {
    private static let keyPressDuration: TimeInterval = 0.03
    private static let postingQueue = DispatchQueue(
        label: "cc.ggbond.mactools.keyboard-key-tap",
        qos: .userInteractive
    )

    fileprivate static let modifierFlags: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate,
        .maskShift,
        .maskAlphaShift,
        .maskSecondaryFn,
    ]

    /// Creates the same atomic event pair used by ``post(_:)``.
    /// Exposed so plugins and tests can inspect or route the events without
    /// duplicating modifier-key semantics.
    public static func makeEvents(
        for keyTap: KeyboardKeyTap,
        ambientFlags: CGEventFlags = CGEventSource.flagsState(.combinedSessionState)
    ) -> (down: CGEvent, up: CGEvent)? {
        guard keyTap.isSupported,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyTap.keyCode),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyTap.keyCode),
            keyDown: false
        ) else {
            return nil
        }

        let preservedFlags = ambientFlags.intersection(modifierFlags)
        down.flags.formUnion(preservedFlags)
        up.flags.formUnion(preservedFlags)
        MacToolsSyntheticInputEvent.mark(down)
        MacToolsSyntheticInputEvent.mark(up)
        let timestamp = DispatchTime.now().uptimeNanoseconds
        down.timestamp = timestamp
        up.timestamp = timestamp + UInt64(keyPressDuration * 1_000_000_000)
        return (down, up)
    }

    @discardableResult
    public static func post(_ keyTap: KeyboardKeyTap) -> Bool {
        guard keyTap.isSupported else { return false }
        postingQueue.async {
            guard let events = makeEvents(for: keyTap) else { return }
            events.down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: keyPressDuration)
            events.up.post(tap: .cghidEventTap)
        }
        return true
    }
}
