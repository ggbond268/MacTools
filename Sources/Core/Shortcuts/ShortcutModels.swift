import AppKit
import Carbon
import Foundation

enum ShortcutScope {
    case global
    case whilePluginActive
}

struct ShortcutModifiers: OptionSet, Hashable, Codable {
    let rawValue: UInt8

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let control = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt8.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0

        if contains(.command) {
            flags |= UInt32(cmdKey)
        }

        if contains(.control) {
            flags |= UInt32(controlKey)
        }

        if contains(.option) {
            flags |= UInt32(optionKey)
        }

        if contains(.shift) {
            flags |= UInt32(shiftKey)
        }

        return flags
    }

    var symbolString: String {
        var output = ""

        if contains(.control) {
            output += "⌃"
        }

        if contains(.option) {
            output += "⌥"
        }

        if contains(.shift) {
            output += "⇧"
        }

        if contains(.command) {
            output += "⌘"
        }

        return output
    }
}

struct ShortcutBinding: Hashable, Codable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers

    var isValid: Bool {
        !modifiers.isEmpty && !ShortcutKeyCode.isModifier(keyCode)
    }
}

enum ShortcutCustomization: Equatable, Codable {
    case inheritDefault
    case custom(ShortcutBinding)
    case cleared

    private enum CodingKeys: String, CodingKey {
        case kind
        case binding
    }

    private enum Kind: String, Codable {
        case inheritDefault
        case custom
        case cleared
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .inheritDefault:
            self = .inheritDefault
        case .custom:
            self = .custom(try container.decode(ShortcutBinding.self, forKey: .binding))
        case .cleared:
            self = .cleared
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .inheritDefault:
            try container.encode(Kind.inheritDefault, forKey: .kind)
        case let .custom(binding):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(binding, forKey: .binding)
        case .cleared:
            try container.encode(Kind.cleared, forKey: .kind)
        }
    }
}

struct PluginShortcutDefinition: Identifiable {
    let id: String
    let title: String
    let description: String
    let actionID: String
    let scope: ShortcutScope
    let defaultBinding: ShortcutBinding?
    let isRequired: Bool
}

struct ShortcutSettingsItem: Identifiable {
    let id: String
    let pluginID: String
    let pluginTitle: String
    let title: String
    let description: String
    let bindingText: String
    let isRequired: Bool
    let canClear: Bool
    let usesDefaultValue: Bool
    let errorMessage: String?
}

enum ShortcutValidationError: LocalizedError {
    case missingModifier
    case modifierOnly
    case requiredShortcut
    case duplicate(ownerDescription: String)

    var errorDescription: String? {
        switch self {
        case .missingModifier:
            return "快捷键至少需要一个修饰键。"
        case .modifierOnly:
            return "快捷键必须包含一个非修饰键。"
        case .requiredShortcut:
            return "该快捷键不能为空。"
        case let .duplicate(ownerDescription):
            return "该快捷键已被“\(ownerDescription)”占用。"
        }
    }
}

enum ShortcutFormatter {
    static func displayString(for binding: ShortcutBinding?) -> String {
        guard let binding else {
            return "None"
        }

        return displayTokens(for: binding).joined(separator: " + ")
    }

    static func displayTokens(for binding: ShortcutBinding) -> [String] {
        var tokens: [String] = []

        if binding.modifiers.contains(.control) {
            tokens.append("CTRL")
        }

        if binding.modifiers.contains(.option) {
            tokens.append("⌥")
        }

        if binding.modifiers.contains(.shift) {
            tokens.append("⇧")
        }

        if binding.modifiers.contains(.command) {
            tokens.append("⌘")
        }

        tokens.append(keyDisplayName(for: binding.keyCode))
        return tokens
    }

    static func keyDisplayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case UInt16(kVK_ANSI_A): return "A"
        case UInt16(kVK_ANSI_B): return "B"
        case UInt16(kVK_ANSI_C): return "C"
        case UInt16(kVK_ANSI_D): return "D"
        case UInt16(kVK_ANSI_E): return "E"
        case UInt16(kVK_ANSI_F): return "F"
        case UInt16(kVK_ANSI_G): return "G"
        case UInt16(kVK_ANSI_H): return "H"
        case UInt16(kVK_ANSI_I): return "I"
        case UInt16(kVK_ANSI_J): return "J"
        case UInt16(kVK_ANSI_K): return "K"
        case UInt16(kVK_ANSI_L): return "L"
        case UInt16(kVK_ANSI_M): return "M"
        case UInt16(kVK_ANSI_N): return "N"
        case UInt16(kVK_ANSI_O): return "O"
        case UInt16(kVK_ANSI_P): return "P"
        case UInt16(kVK_ANSI_Q): return "Q"
        case UInt16(kVK_ANSI_R): return "R"
        case UInt16(kVK_ANSI_S): return "S"
        case UInt16(kVK_ANSI_T): return "T"
        case UInt16(kVK_ANSI_U): return "U"
        case UInt16(kVK_ANSI_V): return "V"
        case UInt16(kVK_ANSI_W): return "W"
        case UInt16(kVK_ANSI_X): return "X"
        case UInt16(kVK_ANSI_Y): return "Y"
        case UInt16(kVK_ANSI_Z): return "Z"
        case UInt16(kVK_ANSI_0): return "0"
        case UInt16(kVK_ANSI_1): return "1"
        case UInt16(kVK_ANSI_2): return "2"
        case UInt16(kVK_ANSI_3): return "3"
        case UInt16(kVK_ANSI_4): return "4"
        case UInt16(kVK_ANSI_5): return "5"
        case UInt16(kVK_ANSI_6): return "6"
        case UInt16(kVK_ANSI_7): return "7"
        case UInt16(kVK_ANSI_8): return "8"
        case UInt16(kVK_ANSI_9): return "9"
        case UInt16(kVK_ANSI_Minus): return "-"
        case UInt16(kVK_ANSI_Equal): return "="
        case UInt16(kVK_ANSI_LeftBracket): return "["
        case UInt16(kVK_ANSI_RightBracket): return "]"
        case UInt16(kVK_ANSI_Backslash): return "\\"
        case UInt16(kVK_ANSI_Semicolon): return ";"
        case UInt16(kVK_ANSI_Quote): return "'"
        case UInt16(kVK_ANSI_Comma): return ","
        case UInt16(kVK_ANSI_Period): return "."
        case UInt16(kVK_ANSI_Slash): return "/"
        case UInt16(kVK_ANSI_Grave): return "`"
        case UInt16(kVK_Return): return "↩"
        case UInt16(kVK_Tab): return "⇥"
        case UInt16(kVK_Space): return "Space"
        case UInt16(kVK_Delete): return "⌫"
        case UInt16(kVK_ForwardDelete): return "⌦"
        case UInt16(kVK_Escape): return "ESC"
        case UInt16(kVK_LeftArrow): return "←"
        case UInt16(kVK_RightArrow): return "→"
        case UInt16(kVK_UpArrow): return "↑"
        case UInt16(kVK_DownArrow): return "↓"
        case UInt16(kVK_Home): return "↖"
        case UInt16(kVK_End): return "↘"
        case UInt16(kVK_PageUp): return "⇞"
        case UInt16(kVK_PageDown): return "⇟"
        case UInt16(kVK_Help): return "Help"
        case UInt16(kVK_F1): return "F1"
        case UInt16(kVK_F2): return "F2"
        case UInt16(kVK_F3): return "F3"
        case UInt16(kVK_F4): return "F4"
        case UInt16(kVK_F5): return "F5"
        case UInt16(kVK_F6): return "F6"
        case UInt16(kVK_F7): return "F7"
        case UInt16(kVK_F8): return "F8"
        case UInt16(kVK_F9): return "F9"
        case UInt16(kVK_F10): return "F10"
        case UInt16(kVK_F11): return "F11"
        case UInt16(kVK_F12): return "F12"
        case UInt16(kVK_F13): return "F13"
        case UInt16(kVK_F14): return "F14"
        case UInt16(kVK_F15): return "F15"
        case UInt16(kVK_F16): return "F16"
        case UInt16(kVK_F17): return "F17"
        case UInt16(kVK_F18): return "F18"
        case UInt16(kVK_F19): return "F19"
        case UInt16(kVK_F20): return "F20"
        default:
            return "Key \(keyCode)"
        }
    }
}

enum ShortcutKeyCode {
    static let escape = UInt16(kVK_Escape)

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),
        63
    ]

    static func isModifier(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }
}

extension ShortcutModifiers {
    static func from(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)

        if normalizedFlags.contains(.command) {
            modifiers.insert(.command)
        }

        if normalizedFlags.contains(.control) {
            modifiers.insert(.control)
        }

        if normalizedFlags.contains(.option) {
            modifiers.insert(.option)
        }

        if normalizedFlags.contains(.shift) {
            modifiers.insert(.shift)
        }

        return modifiers
    }

    static func from(_ flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []

        if flags.contains(.maskCommand) {
            modifiers.insert(.command)
        }

        if flags.contains(.maskControl) {
            modifiers.insert(.control)
        }

        if flags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }

        if flags.contains(.maskShift) {
            modifiers.insert(.shift)
        }

        return modifiers
    }
}

extension NSEvent {
    var shortcutBindingCandidate: ShortcutBinding? {
        ShortcutBinding(
            keyCode: keyCode,
            modifiers: ShortcutModifiers.from(modifierFlags)
        )
    }
}
