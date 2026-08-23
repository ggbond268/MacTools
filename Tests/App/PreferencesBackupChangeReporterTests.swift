import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PreferencesBackupChangeReporterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var reporter: PreferencesBackupChangeReporter!
    private var sources: [PreferencesBackupChangeSource] = []

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesBackupChangeReporterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        reporter = PreferencesBackupChangeReporter()
        reporter.onCommittedChange = { [weak self] source in
            self?.sources.append(source)
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        sources = []
        reporter = nil
        defaults = nil
        super.tearDown()
    }

    func testApplicationStoreReportsOnlySuccessfulMeaningfulWrites() {
        let store = PreferencesBackupStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )

        XCTAssertTrue(store.setAppearancePreference(rawValue: AppAppearancePreference.dark.rawValue))
        XCTAssertEqual(sources, [.application])

        XCTAssertTrue(store.setAppearancePreference(rawValue: AppAppearancePreference.dark.rawValue))
        XCTAssertFalse(store.setAppearancePreference(rawValue: "invalid"))
        XCTAssertEqual(sources, [.application])
    }

    func testSidebarStoreReportsOnlyEffectiveChanges() {
        let store = SettingsSidebarPreferencesStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )
        let items = [
            SettingsSidebarPluginOrderItem(id: "a", title: "A", installedAt: nil),
            SettingsSidebarPluginOrderItem(id: "b", title: "B", installedAt: nil),
        ]

        store.setSortMode(.nameDescending, availableItems: items)
        XCTAssertEqual(sources, [.settingsSidebar])

        store.setSortMode(.nameDescending, availableItems: items)
        XCTAssertEqual(sources, [.settingsSidebar])
    }

    func testShortcutStoreReportsOnlyEffectiveChanges() {
        let store = ShortcutStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )

        store.setCustomization(.cleared, for: "test.shortcut")
        XCTAssertEqual(sources, [.shortcuts])

        store.setCustomization(.cleared, for: "test.shortcut")
        XCTAssertEqual(sources, [.shortcuts])
    }

    func testPluginDisplayStoreReportsOnlyEffectiveChanges() {
        let store = PluginDisplayPreferencesStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )

        store.setOrderedPluginIDs(["b", "a"], defaultPluginIDs: ["a", "b"])
        XCTAssertEqual(sources, [.pluginDisplay])

        store.setOrderedPluginIDs(["b", "a"], defaultPluginIDs: ["a", "b"])
        XCTAssertEqual(sources, [.pluginDisplay])
    }

    func testActionShortcutAssignmentStoreReportsOnlyEffectiveChanges() {
        let store = ActionShortcutAssignmentStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )
        let assignment = ActionShortcutAssignmentRecord(
            reference: testActionReference,
            binding: ShortcutBinding(keyCode: 1, modifiers: .command)
        )

        XCTAssertEqual(store.replaceAll([assignment]), .committed)
        XCTAssertEqual(sources, [.actionShortcutAssignments])

        XCTAssertEqual(store.replaceAll([assignment]), .committed)
        XCTAssertEqual(sources, [.actionShortcutAssignments])
    }

    func testActionInvocationPresetStoreReportsOnlyEffectiveChanges() {
        let store = ActionInvocationPresetStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )
        let preset = ActionInvocationPreset(reference: testActionReference)

        XCTAssertTrue(store.replaceAll([preset]))
        XCTAssertEqual(sources, [.actionInvocationPresets])

        XCTAssertTrue(store.replaceAll([preset]))
        XCTAssertEqual(sources, [.actionInvocationPresets])
    }

    func testAutomationDefinitionsReportButRuntimeHistoryDoesNot() throws {
        let store = WorkflowStore(
            userDefaults: defaults,
            preferencesBackupChangeReporter: reporter
        )

        _ = try store.create(name: "Backup me").get()
        XCTAssertEqual(sources, [.automationDefinitions])

        defaults.set(Data("runtime history".utf8), forKey: "automation.runtime-history.v1")
        XCTAssertEqual(sources, [.automationDefinitions])
    }

    private var testActionReference: ActionReference {
        ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "test-action")
        )
    }
}
