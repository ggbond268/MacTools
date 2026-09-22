import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostApplicationActivityTests: XCTestCase {
    func testHostDeliversInitialAndSubsequentActivityStates() {
        let observer = StubApplicationActivityObserver(state: .displayAsleep)
        let plugin = RecordingApplicationActivityPlugin()
        let suiteName = "PluginHostApplicationActivityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            applicationActivityObserver: observer
        )

        XCTAssertEqual(plugin.states, [.displayAsleep])
        observer.send(.interactive)
        XCTAssertEqual(plugin.states, [.displayAsleep, .interactive])
        withExtendedLifetime(host) {}
    }

    func testHostRefreshesDisplayTopologyAfterWakeSettles() async {
        let observer = StubApplicationActivityObserver(state: .systemSleeping)
        let plugin = RecordingDisplayTopologyPlugin()
        let suiteName = "PluginHostApplicationActivityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            applicationActivityObserver: observer,
            displayTopologyRefreshDelay: .zero
        )

        observer.send(.waking)
        await Task.yield()
        XCTAssertEqual(plugin.displayTopologyRefreshCount, 0)

        observer.send(.displayAsleep)
        await waitUntil { plugin.displayTopologyRefreshCount == 1 }

        XCTAssertEqual(plugin.displayTopologyRefreshCount, 1)
        withExtendedLifetime(host) {}
    }

    func testHostDoesNotRefreshDisplayTopologyWhenWakeReturnsToSleep() async {
        let observer = StubApplicationActivityObserver(state: .systemSleeping)
        let plugin = RecordingDisplayTopologyPlugin()
        let suiteName = "PluginHostApplicationActivityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            applicationActivityObserver: observer,
            displayTopologyRefreshDelay: .zero
        )

        observer.send(.waking)
        observer.send(.systemSleeping)
        for _ in 0..<3 {
            await Task.yield()
        }

        XCTAssertEqual(plugin.displayTopologyRefreshCount, 0)
        withExtendedLifetime(host) {}
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock().now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class StubApplicationActivityObserver: ApplicationActivityObserving {
    private(set) var state: PluginApplicationActivityState
    var onStateChange: ((PluginApplicationActivityState) -> Void)?

    init(state: PluginApplicationActivityState) {
        self.state = state
    }

    func send(_ state: PluginApplicationActivityState) {
        self.state = state
        onStateChange?(state)
    }
}

@MainActor
private final class RecordingApplicationActivityPlugin: MacToolsPlugin,
    PluginApplicationActivityStateHandling {
    let metadata = PluginMetadata(
        id: "activity-recorder",
        title: "Activity Recorder",
        iconName: "bolt",
        iconTint: Color.primary,
        order: 0,
        defaultDescription: ""
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var states: [PluginApplicationActivityState] = []

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        states.append(state)
    }
}

@MainActor
private final class RecordingDisplayTopologyPlugin: MacToolsPlugin, DisplayTopologyRefreshing {
    let metadata = PluginMetadata(
        id: "display-topology-recorder",
        title: "Display Topology Recorder",
        iconName: "display",
        iconTint: Color.primary,
        order: 0,
        defaultDescription: ""
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var displayTopologyRefreshCount = 0

    func refreshDisplayTopology() {
        displayTopologyRefreshCount += 1
    }
}
