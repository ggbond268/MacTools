import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CalendarPluginIntegrationTests: XCTestCase {
    private let suiteName = "CalendarPluginIntegrationTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCalendarPluginAppearsOnlyInComponentPanelAtFullWidth() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let host = PluginHost(
            plugins: [],
            componentPlugins: [CalendarPlugin()],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.id), ["calendar"])
        XCTAssertEqual(host.componentItems.first?.span.width, 4)
        XCTAssertEqual(host.componentItems.first?.span.height, 3)
        XCTAssertEqual(host.permissionCards.map(\.permissionID), ["calendar-events", "calendar-automation"])
    }
}
