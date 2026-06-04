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

    // "AHKY" = 0x4148_4B59. Internal (not private) so a test can assert it never
    // collides with GlobalShortcutManager's signature — the precondition that lets the
    // signature-filtered handler pass foreign hot keys through to the other manager.
    nonisolated static let signature: OSType = 0x4148_4B59

    var onTrigger: ((UUID) -> Void)?

    // `nonisolated(unsafe)`: written only in `init` (via `installHandler`), read only in
    // `deinit` — no concurrent access — so `deinit` can remove the handler without tripping
    // Swift 6's "non-Sendable access from a nonisolated deinit" rule.
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [UUID: RegisteredHotKey] = [:]
    private var idsByCarbon: [UInt32: UUID] = [:]
    private var nextCarbonID: UInt32 = 1

    init() {
        installHandler()
    }

    deinit {
        // 进程级 Carbon handler 用 passUnretained(self) 安装，实例释放前必须移除，
        // 否则悬挂 handler 仍会触发并解引用已释放的 self（use-after-free）。
        // AppHotkeyManager 属于可动态卸载/重载的插件，释放是真实路径，不是理论问题。
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
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
        for (id, binding) in desired {
            if let existing = registeredHotKeys[id], existing.binding == binding { continue }
            unregister(id: id)
            register(id: id, binding: binding)
        }
    }

    func unregisterAll() {
        for id in Array(registeredHotKeys.keys) { unregister(id: id) }
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

    private func register(id: UUID, binding: ShortcutBinding) {
        var ref: EventHotKeyRef?
        let cid = nextCarbonID
        nextCarbonID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: cid)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return }

        registeredHotKeys[id] = RegisteredHotKey(
            entryID: id, binding: binding, reference: ref, carbonID: cid
        )
        idsByCarbon[cid] = id
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
