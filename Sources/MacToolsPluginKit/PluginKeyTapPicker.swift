import Carbon.HIToolbox
import SwiftUI

/// Selects one physical keyboard key as generated output without listening for
/// a real key press. This avoids conflicts with apps that globally monitor the
/// same key while preserving left/right modifier identity.
public struct PluginKeyTapPicker: View {
    public let title: String
    @Binding public var selection: KeyboardKeyTap?
    public let minWidth: CGFloat

    public init(
        title: String,
        selection: Binding<KeyboardKeyTap?>,
        minWidth: CGFloat = 90
    ) {
        self.title = title
        _selection = selection
        self.minWidth = minWidth
    }

    public var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                keyLabel(PluginKitLocalization.keyboardKeyTapUnset, selected: selection == nil)
            }

            Divider()

            ForEach(KeyGroup.all) { group in
                Menu(group.title) {
                    ForEach(group.keys, id: \.keyCode) { keyTap in
                        Button {
                            selection = keyTap
                        } label: {
                            keyLabel(
                                KeyboardKeyTapFormatter.displayString(for: keyTap),
                                selected: selection == keyTap
                            )
                        }
                    }
                }
            }
        } label: {
            PluginShortcutRecorderField(
                displayText: KeyboardKeyTapFormatter.displayString(for: selection),
                isRecording: false,
                minWidth: minWidth
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(KeyboardKeyTapFormatter.displayString(for: selection)))
        .accessibilityHint(Text(PluginKitLocalization.keyboardKeyTapPickerHelp))
    }

    private func keyLabel(_ text: String, selected: Bool) -> some View {
        Label(text, systemImage: selected ? "checkmark" : "keyboard")
    }
}

private struct KeyGroup: Identifiable {
    let id: String
    let title: String
    let keys: [KeyboardKeyTap]

    static var all: [KeyGroup] {
        let definitions: [(String, String, [Int])] = [
            (
                "modifiers",
                PluginKitLocalization.keyboardKeyGroupModifiers,
                [
                    kVK_Command, kVK_RightCommand,
                    kVK_Shift, kVK_RightShift,
                    kVK_Option, kVK_RightOption,
                    kVK_Control, kVK_RightControl,
                    kVK_Function,
                ]
            ),
            (
                "letters",
                "A–Z",
                [
                    kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
                    kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                    kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
                    kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                    kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
                    kVK_ANSI_Z,
                ]
            ),
            (
                "numbers",
                "0–9",
                [
                    kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
                ]
            ),
            (
                "function",
                "F1–F20",
                [
                    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
                    kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                    kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
                ]
            ),
            (
                "navigation",
                PluginKitLocalization.keyboardKeyGroupNavigation,
                [
                    kVK_Return, kVK_Tab, kVK_Space, kVK_Delete, kVK_ForwardDelete,
                    kVK_Escape, kVK_Help, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
                    kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow,
                ]
            ),
            (
                "keypad",
                PluginKitLocalization.keyboardKeyGroupKeypad,
                [
                    kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
                    kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                    kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8,
                    kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply,
                    kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear, kVK_ANSI_KeypadDivide,
                    kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
                ]
            ),
        ]

        var included = Set<UInt16>()
        var groups = definitions.map { id, title, codes in
            let keys = codes
                .map(UInt16.init)
                .map(KeyboardKeyTap.init(keyCode:))
                .filter(\.isSupported)
            included.formUnion(keys.map(\.keyCode))
            return KeyGroup(id: id, title: title, keys: keys)
        }

        let otherKeys = (UInt16(0)...KeyboardKeyTap.maximumSupportedKeyCode)
            .map(KeyboardKeyTap.init(keyCode:))
            .filter { $0.isSupported && !included.contains($0.keyCode) }
            .sorted {
                KeyboardKeyTapFormatter.displayString(for: $0)
                    .localizedStandardCompare(KeyboardKeyTapFormatter.displayString(for: $1)) == .orderedAscending
            }
        groups.append(KeyGroup(
            id: "other",
            title: PluginKitLocalization.keyboardKeyGroupOther,
            keys: otherKeys
        ))
        return groups
    }
}
