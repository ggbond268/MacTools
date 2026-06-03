import Carbon
import MacToolsPluginKit

@MainActor
final class GlobalShortcutManager {
    struct Registration: Equatable {
        let shortcutID: String
        let binding: ShortcutBinding
    }

    private struct RegisteredHotKey {
        let binding: ShortcutBinding
        let reference: EventHotKeyRef
        let carbonID: UInt32
    }

    private nonisolated static let signature: OSType = 0x4D43544C

    var onShortcutTriggered: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [String: RegisteredHotKey] = [:]
    private var shortcutIDsByCarbonID: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 1

    init() {
        installHandlerIfNeeded()
    }

    func updateBindings(_ registrations: [Registration]) {
        installHandlerIfNeeded()

        let targetBindings = Dictionary(uniqueKeysWithValues: registrations.map { ($0.shortcutID, $0.binding) })

        for shortcutID in registeredHotKeys.keys where targetBindings[shortcutID] == nil {
            unregister(shortcutID: shortcutID)
        }

        for registration in registrations {
            if let existing = registeredHotKeys[registration.shortcutID], existing.binding == registration.binding {
                continue
            }

            unregister(shortcutID: registration.shortcutID)
            register(registration)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )
    }

    private func register(_ registration: Registration) {
        var hotKeyReference: EventHotKeyRef?
        let carbonID = nextCarbonID
        nextCarbonID += 1

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: carbonID
        )

        let status = RegisterEventHotKey(
            UInt32(registration.binding.keyCode),
            registration.binding.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )

        guard status == noErr, let hotKeyReference else {
            return
        }

        registeredHotKeys[registration.shortcutID] = RegisteredHotKey(
            binding: registration.binding,
            reference: hotKeyReference,
            carbonID: carbonID
        )
        shortcutIDsByCarbonID[carbonID] = registration.shortcutID
    }

    private func unregister(shortcutID: String) {
        guard let registered = registeredHotKeys.removeValue(forKey: shortcutID) else {
            return
        }

        shortcutIDsByCarbonID.removeValue(forKey: registered.carbonID)
        UnregisterEventHotKey(registered.reference)
    }

    private func unregisterAll() {
        for shortcutID in Array(registeredHotKeys.keys) {
            unregister(shortcutID: shortcutID)
        }
    }

    private func dispatchShortcut(carbonID: UInt32) {
        guard let shortcutID = shortcutIDsByCarbonID[carbonID] else {
            return
        }

        onShortcutTriggered?(shortcutID)
    }

    private nonisolated static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard
            let event,
            let userData
        else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        // 只处理本管理器签名的热键；签名不符返回 eventNotHandledErr，
        // 让 Carbon 继续传递给真正的拥有者（如插件的 AppHotkeyManager）。
        guard hotKeyID.signature == GlobalShortcutManager.signature else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()

        Task { @MainActor in
            manager.dispatchShortcut(carbonID: hotKeyID.id)
        }

        return noErr
    }
}
