import Carbon
import XCTest
import MacToolsPluginKit
@testable import AppHotkeyPlugin

@MainActor
final class AppHotkeyStoreTests: XCTestCase {
    func testCommonApplicationShortcutBindingsRequireConflictWarning() {
        XCTAssertTrue(
            CommonApplicationShortcutBindings.requiresConflictWarning(
                for: ShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command])
            )
        )
        XCTAssertTrue(
            CommonApplicationShortcutBindings.requiresConflictWarning(
                for: ShortcutBinding(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command])
            )
        )
        XCTAssertFalse(
            CommonApplicationShortcutBindings.requiresConflictWarning(
                for: ShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .shift])
            )
        )
    }

    func testAddUpdateDeleteAndPersistEntries() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari"
        )
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])

        store.addEntry(entry)
        store.updateShortcut(id: entry.id, shortcut: binding)

        let reloaded = AppHotkeyStore(storage: storage)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.displayName, "Safari")
        XCTAssertEqual(reloaded.entries.first?.shortcut, binding)

        reloaded.deleteEntry(id: entry.id)
        XCTAssertTrue(AppHotkeyStore(storage: storage).entries.isEmpty)
    }

    func testConflictDetectionIgnoresExcludedEntry() {
        let store = AppHotkeyStore(storage: InMemoryPluginStorage())
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .control])
        let first = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            displayName: "A",
            shortcut: binding
        )
        let second = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/B.app"),
            displayName: "B"
        )

        store.addEntry(first)
        store.addEntry(second)

        XCTAssertEqual(store.conflictEntry(for: binding, excludingID: second.id)?.id, first.id)
        XCTAssertNil(store.conflictEntry(for: binding, excludingID: first.id))
    }

}

@MainActor
final class AppHotkeyPluginTests: XCTestCase {

    func testEntriesPublishConcreteActionsAndLegacyBindingsMigrateOnce() throws {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        let binding = ShortcutBinding(keyCode: 4, modifiers: [.command, .option])
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari",
            shortcut: binding
        )
        store.addEntry(entry)
        let plugin = makePlugin(storage: storage)

        let catalogEntry = try XCTUnwrap(plugin.actionCatalogEntries.first)
        XCTAssertEqual(catalogEntry.title, "Safari")
        XCTAssertEqual(catalogEntry.reference.key.actionID, "launch")
        XCTAssertEqual(
            plugin.legacyActionShortcutAssignments,
            [
                LegacyActionShortcutAssignment(
                    reference: catalogEntry.reference,
                    binding: binding
                ),
            ]
        )

        plugin.legacyActionShortcutsDidMigrate()

        XCTAssertTrue(plugin.legacyActionShortcutAssignments.isEmpty)
        XCTAssertNil(AppHotkeyStore(storage: storage).entries.first?.shortcut)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.reference, catalogEntry.reference)
    }

    func testCanonicalLaunchWaitsForLauncherCompletionAndSurfacesFailure() async throws {
        let storage = InMemoryPluginStorage()
        AppHotkeyStore(storage: storage).addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
            displayName: "Test"
        ))
        let launcher = AppHotkeyLauncherMock()
        let plugin = AppHotkeyPlugin(
            context: PluginRuntimeContext(pluginID: "app-hotkey", storage: storage),
            applicationLauncher: launcher
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        )
        let resultTask = Task { await handle.result() }
        for _ in 0 ..< 20 where launcher.callCount == 0 { await Task.yield() }

        XCTAssertEqual(launcher.callCount, 1)
        XCTAssertFalse(resultTask.isCancelled)
        launcher.finish(throwing: NSError(
            domain: "AppHotkeyPluginTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Launch rejected"]
        ))

        let result = await resultTask.value
        XCTAssertEqual(result, .failed(message: "Launch rejected"))
    }

    func testSystemLauncherReportsFrontmostHideFailure() async {
        let launcher = SystemAppHotkeyApplicationLauncher(
            bundleIdentifier: { _ in "com.example.test" },
            frontmostBundleIdentifier: { "com.example.test" },
            hideFrontmost: { false },
            openApplication: { _ in XCTFail("Should not open a frontmost app") }
        )

        do {
            try await launcher.launch(URL(fileURLWithPath: "/Applications/Test.app"))
            XCTFail("Expected hide failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "AppHotkeyPlugin")
        }
    }

    private func makePlugin() -> AppHotkeyPlugin {
        makePlugin(storage: InMemoryPluginStorage())
    }

    private func makePlugin(storage: InMemoryPluginStorage) -> AppHotkeyPlugin {
        AppHotkeyPlugin(context: PluginRuntimeContext(pluginID: "app-hotkey", storage: storage))
    }
}

@MainActor
private final class AppHotkeyLauncherMock: AppHotkeyApplicationLaunching {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Error>?

    func launch(_ bundleURL: URL) async throws {
        callCount += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(throwing error: Error? = nil) {
        let continuation = continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

@MainActor
private final class InMemoryPluginStorage: PluginStorage {
    private var store: [String: Any] = [:]

    func object(forKey key: String) -> Any? { store[key] }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func string(forKey key: String) -> String? { store[key] as? String }
    func stringArray(forKey key: String) -> [String]? { store[key] as? [String] }
    func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard store[key] == nil, let value = store[legacyKey] else { return }
        store[key] = value
        store.removeValue(forKey: legacyKey)
    }
}
