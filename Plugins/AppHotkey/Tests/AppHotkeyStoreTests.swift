import XCTest
@testable import AppHotkeyPlugin
import MacToolsPluginKit

// MARK: - AppHotkeyStore Tests

@MainActor
final class AppHotkeyStoreTests: XCTestCase {

    private func makeStore() -> (AppHotkeyStore, InMemoryPluginStorage) {
        let storage = InMemoryPluginStorage()
        return (AppHotkeyStore(storage: storage), storage)
    }

    func testAddEntry() {
        let (store, _) = makeStore()
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari"
        )
        store.addEntry(entry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.displayName, "Safari")
    }

    func testDeleteEntry() {
        let (store, _) = makeStore()
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari"
        )
        store.addEntry(entry)
        store.deleteEntry(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDeleteNonExistentEntryIsNoOp() {
        let (store, _) = makeStore()
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari"
        ))
        store.deleteEntry(id: UUID())
        XCTAssertEqual(store.entries.count, 1)
    }

    func testUpdateShortcut() {
        let (store, _) = makeStore()
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            displayName: "Xcode"
        )
        store.addEntry(entry)

        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.updateShortcut(id: entry.id, shortcut: binding)
        XCTAssertEqual(store.entries.first?.shortcut, binding)
    }

    func testUpdateShortcutForNonExistentIDIsNoOp() {
        let (store, _) = makeStore()
        store.updateShortcut(id: UUID(), shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command]))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearShortcut() {
        let (store, _) = makeStore()
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            displayName: "Xcode",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        )
        store.addEntry(entry)
        store.updateShortcut(id: entry.id, shortcut: nil)
        XCTAssertNil(store.entries.first?.shortcut)
    }

    func testConflictDetection() {
        let (store, _) = makeStore()
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .control])

        let entryA = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            displayName: "AppA"
        )
        let entryB = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/B.app"),
            displayName: "AppB"
        )

        store.addEntry(entryA)
        store.updateShortcut(id: entryA.id, shortcut: binding)
        store.addEntry(entryB)

        // entryB 使用相同快捷键时应检测到冲突
        let conflict = store.conflictEntry(for: binding, excludingID: entryB.id)
        XCTAssertEqual(conflict?.id, entryA.id)

        // entryA 自身不算冲突
        let selfConflict = store.conflictEntry(for: binding, excludingID: entryA.id)
        XCTAssertNil(selfConflict)
    }

    func testConflictWithNoExcludedID() {
        let (store, _) = makeStore()
        let binding = ShortcutBinding(keyCode: 5, modifiers: [.command])
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            displayName: "AppA",
            shortcut: binding
        )
        store.addEntry(entry)
        XCTAssertEqual(store.conflictEntry(for: binding)?.id, entry.id)
    }

    func testNoConflictForDifferentBinding() {
        let (store, _) = makeStore()
        let bindingA = ShortcutBinding(keyCode: 0, modifiers: [.command])
        let bindingB = ShortcutBinding(keyCode: 1, modifiers: [.command])

        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            displayName: "AppA",
            shortcut: bindingA
        )
        store.addEntry(entry)

        XCTAssertNil(store.conflictEntry(for: bindingB))
    }

    func testPersistenceAcrossReload() {
        let storage = InMemoryPluginStorage()

        let store1 = AppHotkeyStore(storage: storage)
        let binding = ShortcutBinding(keyCode: 3, modifiers: [.command, .shift])
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
            displayName: "终端",
            shortcut: binding
        )
        store1.addEntry(entry)

        // 重新加载同一 storage
        let store2 = AppHotkeyStore(storage: storage)
        XCTAssertEqual(store2.entries.count, 1)
        XCTAssertEqual(store2.entries.first?.displayName, "终端")
        XCTAssertEqual(store2.entries.first?.shortcut, binding)
    }

    func testPersistenceAfterDelete() {
        let storage = InMemoryPluginStorage()
        let store1 = AppHotkeyStore(storage: storage)
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari"
        )
        store1.addEntry(entry)
        store1.deleteEntry(id: entry.id)

        let store2 = AppHotkeyStore(storage: storage)
        XCTAssertTrue(store2.entries.isEmpty)
    }

    func testMultipleEntriesOrder() {
        let (store, _) = makeStore()
        let names = ["Safari", "Xcode", "Terminal"]
        for name in names {
            store.addEntry(AppShortcutEntry(
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                displayName: name
            ))
        }
        XCTAssertEqual(store.entries.map(\.displayName), names)
    }

    func testEmptyStorageStartsWithNoEntries() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
    }
}

// MARK: - AppShortcutEntry Tests

@MainActor
final class AppShortcutEntryTests: XCTestCase {

    func testBundleURLRoundtrip() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        let entry = AppShortcutEntry(bundleURL: url, displayName: "Safari")
        XCTAssertEqual(entry.bundleURL, url)
    }

    func testDefaultIDIsUnique() {
        let a = AppShortcutEntry(bundleURL: URL(fileURLWithPath: "/Applications/A.app"), displayName: "A")
        let b = AppShortcutEntry(bundleURL: URL(fileURLWithPath: "/Applications/B.app"), displayName: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testEquality() {
        let id = UUID()
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command])
        let a = AppShortcutEntry(id: id, bundleURL: url, displayName: "Safari", shortcut: binding)
        let b = AppShortcutEntry(id: id, bundleURL: url, displayName: "Safari", shortcut: binding)
        XCTAssertEqual(a, b)
    }

    func testInequalityOnDifferentShortcut() {
        let id = UUID()
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        let a = AppShortcutEntry(id: id, bundleURL: url, displayName: "Safari",
                                 shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command]))
        let b = AppShortcutEntry(id: id, bundleURL: url, displayName: "Safari",
                                 shortcut: ShortcutBinding(keyCode: 1, modifiers: [.command]))
        XCTAssertNotEqual(a, b)
    }

    func testCodableRoundtrip() throws {
        let binding = ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            displayName: "Xcode",
            shortcut: binding
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AppShortcutEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}

// MARK: - AppHotkeyPlugin Tests

@MainActor
final class AppHotkeyPluginTests: XCTestCase {

    private func makePlugin() -> AppHotkeyPlugin {
        makePlugin(storage: InMemoryPluginStorage())
    }

    private func makePlugin(storage: InMemoryPluginStorage) -> AppHotkeyPlugin {
        let context = PluginRuntimeContext(pluginID: "app-hotkey", storage: storage)
        return AppHotkeyPlugin(context: context)
    }

    // MARK: isEnabled 初始化

    func testDefaultEnabledWhenStorageEmpty() {
        let plugin = makePlugin()
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testLoadEnabledFalseFromStorage() {
        let storage = InMemoryPluginStorage()
        storage.set(false, forKey: "isEnabled")
        let plugin = makePlugin(storage: storage)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testLoadEnabledTrueFromStorage() {
        let storage = InMemoryPluginStorage()
        storage.set(true, forKey: "isEnabled")
        let plugin = makePlugin(storage: storage)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    // MARK: primaryPanelState 字幕

    func testSubtitleWhenNoEntries() {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "暂无绑定，前往设置配置")
    }

    func testSubtitleWhenEnabledWithOneBoundEntry() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        ))
        let plugin = makePlugin(storage: storage)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 个快捷键已启用")
    }

    func testSubtitleWhenEnabledWithMultipleBoundEntries() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        for (i, name) in ["Safari", "Xcode", "Terminal"].enumerated() {
            store.addEntry(AppShortcutEntry(
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                displayName: name,
                shortcut: ShortcutBinding(keyCode: UInt16(i), modifiers: [.command])
            ))
        }
        let plugin = makePlugin(storage: storage)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "3 个快捷键已启用")
    }

    func testSubtitleCountsOnlyBoundEntries() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        // 一条有快捷键，一条没有
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        ))
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            displayName: "Xcode"
        ))
        let plugin = makePlugin(storage: storage)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 个快捷键已启用")
    }

    func testSubtitleWhenDisabledWithBoundEntries() {
        let storage = InMemoryPluginStorage()
        storage.set(false, forKey: "isEnabled")
        let store = AppHotkeyStore(storage: storage)
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        ))
        let plugin = makePlugin(storage: storage)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "快捷键已暂停")
    }

    func testSubtitleWhenDisabledWithNoEntries() {
        let storage = InMemoryPluginStorage()
        storage.set(false, forKey: "isEnabled")
        let plugin = makePlugin(storage: storage)
        // 无绑定时即使禁用，也提示去配置
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "暂无绑定，前往设置配置")
    }

    // MARK: handleAction

    func testHandleSetSwitchFalsePersistsAndUpdatesState() {
        let storage = InMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        var stateChangeCalled = false
        plugin.onStateChange = { stateChangeCalled = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.bool(forKey: "isEnabled"), false)
        XCTAssertTrue(stateChangeCalled)
    }

    func testHandleSetSwitchTruePersistsAndUpdatesState() {
        let storage = InMemoryPluginStorage()
        storage.set(false, forKey: "isEnabled")
        let plugin = makePlugin(storage: storage)

        var stateChangeCalled = false
        plugin.onStateChange = { stateChangeCalled = true }

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.bool(forKey: "isEnabled"), true)
        XCTAssertTrue(stateChangeCalled)
    }

    func testHandleSetSwitchTogglesSubtitle() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        ))
        let plugin = makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(false))
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "快捷键已暂停")

        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 个快捷键已启用")
    }

    // MARK: 静态属性

    func testMetadataID() {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.metadata.id, "app-hotkey")
    }

    func testPrimaryPanelStateIsVisible() {
        let plugin = makePlugin()
        XCTAssertTrue(plugin.primaryPanelState.isVisible)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testNoPermissionRequirements() {
        let plugin = makePlugin()
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testNoShortcutDefinitions() {
        let plugin = makePlugin()
        XCTAssertTrue(plugin.shortcutDefinitions.isEmpty)
    }
}

// MARK: - Test Support

@MainActor
fileprivate final class InMemoryPluginStorage: PluginStorage {
    private var store: [String: Any] = [:]

    func object(forKey key: String) -> Any? { store[key] }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func string(forKey key: String) -> String? { store[key] as? String }
    func stringArray(forKey key: String) -> [String]? { store[key] as? [String] }
    func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            store[key] = value
        } else {
            store.removeValue(forKey: key)
        }
    }

    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey: String, to key: String) {}
}

// MARK: - Registration Failure Surfacing

@MainActor
final class AppHotkeyRegistrationFailureTests: XCTestCase {

    private func entry(_ name: String) -> AppShortcutEntry {
        AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            displayName: name,
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        )
    }

    func testManagerRecordsFailedRegistrations() {
        // Registrar that always fails, simulating the OS rejecting the combo.
        let manager = AppHotkeyManager(registrar: { _, _, _ in nil })
        let e = entry("Safari")

        manager.sync(entries: [e])

        XCTAssertEqual(manager.failedEntryIDs, [e.id])
    }

    func testManagerClearsFailuresWhenEntriesRemoved() {
        let manager = AppHotkeyManager(registrar: { _, _, _ in nil })
        let e = entry("Safari")
        manager.sync(entries: [e])
        XCTAssertFalse(manager.failedEntryIDs.isEmpty)

        manager.sync(entries: [])

        XCTAssertTrue(manager.failedEntryIDs.isEmpty)
    }

    func testPluginSurfacesRegistrationFailureWithName() {
        let storage = InMemoryPluginStorage()
        // Seed the shared storage with an entry that has a shortcut.
        AppHotkeyStore(storage: storage).addEntry(entry("Safari"))

        let context = PluginRuntimeContext(pluginID: "app-hotkey", storage: storage)
        let manager = AppHotkeyManager(registrar: { _, _, _ in nil })
        let plugin = AppHotkeyPlugin(context: context, hotkeyManager: manager)

        plugin.activate(context: context) // triggers syncHotkeys()

        let message = plugin.primaryPanelState.errorMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Safari") == true)
        XCTAssertTrue(message?.contains("注册失败") == true)
    }

    func testPluginHasNoErrorWhenRegistrationSucceeds() {
        let storage = InMemoryPluginStorage()
        AppHotkeyStore(storage: storage).addEntry(entry("Safari"))

        let context = PluginRuntimeContext(pluginID: "app-hotkey", storage: storage)
        // Registrar reports success by returning a non-nil reference.
        let manager = AppHotkeyManager(registrar: { _, _, hotKeyID in
            OpaquePointer(bitPattern: Int(hotKeyID.id) + 1)
        })
        let plugin = AppHotkeyPlugin(context: context, hotkeyManager: manager)

        plugin.activate(context: context)

        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }
}
