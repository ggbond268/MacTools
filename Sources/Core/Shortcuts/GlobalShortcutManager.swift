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
        var shortcutIDs: [String]
    }

    private static let signature: OSType = 0x4D43544C

    var onShortcutTriggered: ((String) -> Void)?
    var onShortcutReleased: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [ShortcutBinding: RegisteredHotKey] = [:]
    private var shortcutIDsByCarbonID: [UInt32: [String]] = [:]
    private var nextCarbonID: UInt32 = 1

    init() {
        installHandlerIfNeeded()
    }

    func updateBindings(_ registrations: [Registration]) {
        installHandlerIfNeeded()

        let targetGroups = registrations.reduce(into: [ShortcutBinding: [String]]()) { result, registration in
            guard registration.binding.isValid else {
                return
            }

            if result[registration.binding]?.contains(registration.shortcutID) == true {
                return
            }

            result[registration.binding, default: []].append(registration.shortcutID)
        }

        for binding in Array(registeredHotKeys.keys) where targetGroups[binding] == nil {
            unregister(binding: binding)
        }

        for (binding, shortcutIDs) in targetGroups {
            if var existing = registeredHotKeys[binding] {
                existing.shortcutIDs = shortcutIDs
                registeredHotKeys[binding] = existing
                shortcutIDsByCarbonID[existing.carbonID] = shortcutIDs
                continue
            }

            register(binding: binding, shortcutIDs: shortcutIDs)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        // Register/listen on the event dispatcher target, matching Magnet and MASShortcut. In this
        // app's run loop, global hotkey events are not routed to `GetApplicationEventTarget()`, so
        // hotkeys can register successfully but never trigger callbacks.
        _ = eventTypes.withUnsafeBufferPointer { buffer in
            InstallEventHandler(
                GetEventDispatcherTarget(),
                Self.hotKeyHandler,
                buffer.count,
                buffer.baseAddress,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                &handlerRef
            )
        }
    }

    private func register(binding: ShortcutBinding, shortcutIDs: [String]) {
        var hotKeyReference: EventHotKeyRef?
        let carbonID = nextCarbonID
        nextCarbonID += 1

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: carbonID
        )

        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyReference
        )

        guard status == noErr, let hotKeyReference else {
            return
        }

        registeredHotKeys[binding] = RegisteredHotKey(
            binding: binding,
            reference: hotKeyReference,
            carbonID: carbonID,
            shortcutIDs: shortcutIDs
        )
        shortcutIDsByCarbonID[carbonID] = shortcutIDs
    }

    private func unregister(binding: ShortcutBinding) {
        guard let registered = registeredHotKeys.removeValue(forKey: binding) else {
            return
        }

        shortcutIDsByCarbonID.removeValue(forKey: registered.carbonID)
        UnregisterEventHotKey(registered.reference)
    }

    private func unregisterAll() {
        for binding in Array(registeredHotKeys.keys) {
            unregister(binding: binding)
        }
    }

    private func dispatchShortcut(carbonID: UInt32, isReleased: Bool) {
        guard let shortcutIDs = shortcutIDsByCarbonID[carbonID] else {
            return
        }

        for shortcutID in shortcutIDs {
            if isReleased {
                onShortcutReleased?(shortcutID)
            } else {
                onShortcutTriggered?(shortcutID)
            }
        }
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

        guard hotKeyID.signature == 0x4D43544C else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
        let isReleased = GetEventKind(event) == UInt32(kEventHotKeyReleased)

        Task { @MainActor in
            manager.dispatchShortcut(carbonID: hotKeyID.id, isReleased: isReleased)
        }

        return noErr
    }
}
