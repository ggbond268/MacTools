import Carbon
import Foundation
import MacToolsPluginKit

/// 管理 Carbon Event 热键注册。与 GlobalShortcutManager 平行运行，
/// 使用独立的 OSType 签名（"AHKY"），避免 Carbon ID 碰撞。
@MainActor
final class AppHotkeyManager {
    private struct RegisteredHotKey {
        let entryID: UUID
        let binding: ShortcutBinding
        let reference: EventHotKeyRef
        let carbonID: UInt32
    }

    // "AHKY" = 0x4148_4B59
    private static let signature: OSType = 0x4148_4B59

    var onTrigger: ((UUID) -> Void)?

    /// Performs the actual Carbon registration. Returns the hot-key reference on
    /// success, or `nil` if registration failed (e.g. the combo is already taken
    /// by another app — `eventHotKeyExistsErr`). Injectable for testing.
    typealias Registrar = (_ keyCode: UInt32, _ modifiers: UInt32, _ hotKeyID: EventHotKeyID) -> EventHotKeyRef?

    /// Entry IDs whose shortcut could not be registered on the last `sync`.
    private(set) var failedEntryIDs: Set<UUID> = []

    private let registrar: Registrar
    private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [UUID: RegisteredHotKey] = [:]
    private var idsByCarbon: [UInt32: UUID] = [:]
    private var nextCarbonID: UInt32 = 1

    init(registrar: Registrar? = nil) {
        self.registrar = registrar ?? { keyCode, modifiers, hotKeyID in
            var ref: EventHotKeyRef?
            // 与 installHandler 一致用事件分发目标：全局热键不会路由到
            // GetApplicationEventTarget()，否则注册成功却从不触发（main 的路由修复）。
            let status = RegisterEventHotKey(
                keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref
            )
            guard status == noErr, let ref else { return nil }
            return ref
        }
        installHandler()
    }

    /// 根据当前 entries 重新同步热键注册（增量 diff）。
    func sync(entries: [AppShortcutEntry]) {
        let desired = Dictionary(
            uniqueKeysWithValues: entries.compactMap { e -> (UUID, ShortcutBinding)? in
                guard let s = e.shortcut else { return nil }
                return (e.id, s)
            }
        )

        // 移除已失效的热键
        for id in registeredHotKeys.keys where desired[id] == nil {
            unregister(id: id)
        }

        // 新增或更新
        var failures: Set<UUID> = []
        for (id, binding) in desired {
            if let existing = registeredHotKeys[id], existing.binding == binding { continue }
            unregister(id: id)
            if !register(id: id, binding: binding) {
                failures.insert(id)
            }
        }
        failedEntryIDs = failures
    }

    func unregisterAll() {
        for id in Array(registeredHotKeys.keys) { unregister(id: id) }
        failedEntryIDs = []
    }

    /// 录制期间临时注销指定条目的热键，录制结束后由调用方调用 `sync` 恢复。
    func temporarilyDisable(id: UUID) {
        unregister(id: id)
    }

    // MARK: Private

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // 与宿主全局快捷键同样使用事件分发目标，避免不同 Carbon target
        // 的路由差异。handler 仍通过独立 signature 只处理 AppHotkey 事件。
        InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )
    }

    /// Returns `true` on success, `false` if the OS rejected the registration.
    @discardableResult
    private func register(id: UUID, binding: ShortcutBinding) -> Bool {
        let cid = nextCarbonID
        nextCarbonID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: cid)
        guard let ref = registrar(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            hotKeyID
        ) else {
            return false
        }

        registeredHotKeys[id] = RegisteredHotKey(
            entryID: id, binding: binding, reference: ref, carbonID: cid
        )
        idsByCarbon[cid] = id
        return true
    }

    private func unregister(id: UUID) {
        guard let registered = registeredHotKeys.removeValue(forKey: id) else { return }
        idsByCarbon.removeValue(forKey: registered.carbonID)
        UnregisterEventHotKey(registered.reference)
    }

    private func dispatch(carbonID: UInt32) {
        guard let id = idsByCarbon[carbonID] else { return }
        onTrigger?(id)
    }

    private nonisolated static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

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
        guard status == noErr else { return status }

        guard hotKeyID.signature == 0x4148_4B59 else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<AppHotkeyManager>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            manager.dispatch(carbonID: hotKeyID.id)
        }
        return noErr
    }
}
