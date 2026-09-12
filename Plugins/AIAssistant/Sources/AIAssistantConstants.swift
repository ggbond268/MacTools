import Carbon.HIToolbox
import Foundation
import MacToolsPluginKit

enum AIAssistantConstants {
    static let pluginID = "ai-assistant"

    enum PermissionID {
        static let accessibility = "accessibility"
        static let automation = "automation"
    }

    enum StorageKey {
        static let shortcutEnabled = "ai-assistant.shortcut.enabled"
        static let providerProfiles = "ai-assistant.providers.profiles"
        static let prompts = "ai-assistant.prompts"
    }

    enum Defaults {
        static let shortcutEnabled = true
        static let translateShortcut = ShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: [.option])
        static let summarizeShortcut = ShortcutBinding(keyCode: UInt16(kVK_ANSI_2), modifiers: [.option])
        static let polishShortcut = ShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: [.option])
    }
}
