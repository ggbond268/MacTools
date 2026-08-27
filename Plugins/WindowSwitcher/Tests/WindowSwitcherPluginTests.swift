import AppKit
import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import WindowSwitcherPlugin

@MainActor
private final class WindowSwitcherMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
final class WindowSwitcherPluginTests: XCTestCase {
    func testManifestActionMatchesRuntimePolicy() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )

        try PluginManifestActionAssertions.assertConsistency(
            pluginDirectoryName: "WindowSwitcher",
            definitions: plugin.actionDefinitions,
            permissionIDs: plugin.permissionRequirementIDs(for:)
        )
    }

    func testShortcutRecorderUsesGroupSummaryWithoutDuplicateControlLabel() {
        let plugin = WindowSwitcherPlugin(accessibilityTrusted: { true })
        let definition = plugin.shortcutDefinitions.first

        XCTAssertNil(definition?.settingsControlTitle)
        XCTAssertNil(definition?.settingsControlSystemImage)
    }

    func testPublishesForegroundCanonicalActionWithAccessibilityRequirement() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.actionID, WindowSwitcherConstants.shortcutActionID)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: definition.key),
            [WindowSwitcherConstants.accessibilityPermissionID]
        )
        XCTAssertEqual(
            plugin.actionAvailability(for: ActionReference(key: definition.key)),
            .available
        )
    }

    func testCanonicalActionIsUnavailableWhenWindowSwitcherIsDisabled() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )
        plugin.store.setEnabled(false)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertFalse(
            plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable
        )
    }

    func testWorkspaceNotificationHopsSafelyToMainActor() async {
        let center = NotificationCenter()
        let catalog = WindowSwitcherAppCatalog(notificationCenter: center)
        let changed = expectation(description: "catalog reports a workspace change")
        catalog.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            changed.fulfill()
        }
        catalog.start()

        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        await fulfillment(of: [changed], timeout: 1)
        catalog.stop()
    }

    func testModePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setMode(.directCycle)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(loaded.configuration.mode, .directCycle)
    }

    func testSortModePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setSortMode(.fixed)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(loaded.configuration.sortMode, .fixed)
    }

    func testLegacyConfigurationDefaultsToEnabled() throws {
        let storage = WindowSwitcherMemoryStorage()
        let data = try XCTUnwrap(#"{"mode":"directCycle"}"#.data(using: .utf8))
        storage.set(data, forKey: "configuration")

        let store = WindowSwitcherStore(storage: storage)

        XCTAssertTrue(store.configuration.isEnabled)
        XCTAssertEqual(store.configuration.mode, .directCycle)
        XCTAssertEqual(store.configuration.sortMode, .recentUse)
    }

    func testEnabledStatePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setEnabled(false)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertFalse(loaded.configuration.isEnabled)
    }

    func testObsoleteShortcutAssignmentsAreDiscarded() throws {
        let storage = WindowSwitcherMemoryStorage()
        storage.set(
            try JSONEncoder().encode(["bundle:com.apple.Safari": "s"]),
            forKey: "shortcut-assignments"
        )

        let store = WindowSwitcherStore(storage: storage)

        XCTAssertEqual(store.shortcutBindings.manual, [:])
        XCTAssertEqual(store.shortcutBindings.automatic, [:])
        XCTAssertNil(storage.data(forKey: "shortcut-assignments"))
        XCTAssertNil(storage.data(forKey: "shortcut-bindings"))
    }

    func testShortcutAssignmentUsesLettersThenDigitsThenCommandKeys() {
        let entries = (0..<73).map { index in
            makeEntry(index: index, appName: "\(index)")
        }

        let assigned = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries)

        XCTAssertEqual(assigned[0].shortcutToken, "f")
        XCTAssertEqual(assigned[1].shortcutToken, "j")
        XCTAssertEqual(assigned[25].shortcutToken, "y")
        XCTAssertEqual(assigned[26].shortcutToken, "1")
        XCTAssertEqual(assigned[35].shortcutToken, "0")
        XCTAssertEqual(assigned[36].shortcutToken, "cmd+f")
        XCTAssertEqual(assigned[71].shortcutToken, "cmd+0")
        XCTAssertNil(assigned[72].shortcutToken)
    }

    func testShortcutAssignmentPrefersApplicationInitials() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ]

        let assigned = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries)

        XCTAssertEqual(assigned[0].shortcutToken, "s")
        XCTAssertEqual(assigned[1].shortcutToken, "f")
    }

    func testShortcutAssignmentKeepsStoredTokensAcrossOrderChanges() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
        ]
        let first = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: WindowSwitcherShortcutBindingState()
        )
        let reordered = [
            makeEntry(index: 1, appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ]

        let second = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: reordered,
            bindingState: first.bindingState
        )

        XCTAssertEqual(first.entries[0].shortcutToken, "s")
        XCTAssertEqual(first.entries[1].shortcutToken, "f")
        XCTAssertEqual(second.entries[0].shortcutToken, "f")
        XCTAssertEqual(second.entries[1].shortcutToken, "s")
    }

    func testManualShortcutTakesPriorityOverConflictingAutomaticShortcut() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ]
        let state = WindowSwitcherShortcutBindingState(
            manual: ["bundle:com.apple.Safari": "f"],
            automatic: ["bundle:com.apple.finder": "f"]
        )

        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: state
        )

        XCTAssertEqual(result.entries[0].shortcutToken, "f")
        XCTAssertEqual(result.entries[1].shortcutToken, "j")
        XCTAssertEqual(result.bindingState.manual["bundle:com.apple.Safari"], "f")
        XCTAssertEqual(result.bindingState.automatic["bundle:com.apple.finder"], "j")
    }

    func testManualShortcutRejectsConflictWithRunningEntry() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ])
        let finderToken = entries[1].shortcutToken
        let bindingsBeforeConflict = store.shortcutBindings

        let result = store.setManualShortcut(finderToken, for: entries[0].id, in: entries)

        guard case .conflict = result else {
            return XCTFail("Expected an active shortcut conflict.")
        }
        XCTAssertEqual(store.shortcutBindings, bindingsBeforeConflict)
        XCTAssertEqual(store.assignShortcuts(to: entries), entries)
    }

    func testManualShortcutPersistsAndSurvivesSortingChanges() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ])

        let result = store.setManualShortcut("q", for: entries[0].id, in: entries)
        guard case let .updated(updatedEntries) = result else {
            return XCTFail("Expected a saved manual shortcut.")
        }

        XCTAssertEqual(updatedEntries[0].shortcutToken, "q")
        let loaded = WindowSwitcherStore(storage: storage)
        let reordered = loaded.assignShortcuts(to: [entries[1], entries[0]])
        XCTAssertEqual(reordered[0].shortcutToken, entries[1].shortcutToken)
        XCTAssertEqual(reordered[1].shortcutToken, "q")
        XCTAssertEqual(loaded.shortcutBindings.manual["bundle:com.apple.Safari"], "q")
    }

    func testManualShortcutRejectsMultiKeyAndUnsupportedInput() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])

        for invalidToken in ["ff", "f1", "s1", "cmd+ff", "cmd+-", "⌘a", "窗口"] {
            guard case .unavailable = store.setManualShortcut(
                invalidToken,
                for: entries[0].id,
                in: entries
            ) else {
                return XCTFail("Expected \(invalidToken) to be rejected.")
            }
        }
        XCTAssertTrue(store.shortcutBindings.manual.isEmpty)
    }

    func testClearingManualShortcutRestoresAutomaticShortcut() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])
        XCTAssertEqual(entries[0].shortcutToken, "s")
        guard case let .updated(customized) = store.setManualShortcut(
            "q",
            for: entries[0].id,
            in: entries
        ) else {
            return XCTFail("Expected a saved manual shortcut.")
        }

        let result = store.setManualShortcut(nil, for: customized[0].id, in: customized)

        guard case let .updated(restored) = result else {
            return XCTFail("Expected the manual shortcut to be cleared.")
        }
        XCTAssertEqual(restored[0].shortcutToken, "s")
        XCTAssertTrue(store.shortcutBindings.manual.isEmpty)
        XCTAssertEqual(store.shortcutBindings.automatic["bundle:com.apple.Safari"], "s")
    }

    func testMultiWindowEntriesUseDistinctPersistentBindingIdentities() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])

        let result = store.setManualShortcut("q", for: entries[1].id, in: entries)

        guard case let .updated(updated) = result else {
            return XCTFail("Expected a saved shortcut for the second window.")
        }
        XCTAssertEqual(updated[0].shortcutToken, "s")
        XCTAssertEqual(updated[1].shortcutToken, "q")
        XCTAssertEqual(
            store.shortcutBindings.manual["bundle:com.apple.Safari#window:2"],
            "q"
        )
    }

    private func makeEntry(
        index: Int,
        appName: String,
        bundleIdentifier: String? = nil
    ) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: "app-\(index)",
            processIdentifier: pid_t(index + 100),
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: nil,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            shortcutToken: nil
        )
    }
}
