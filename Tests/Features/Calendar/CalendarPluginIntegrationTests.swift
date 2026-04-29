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

    func testCalendarPermissionActionRequestsEventAccess() async {
        let service = MockCalendarPermissionService(
            authorization: .notDetermined,
            requestResult: .fullAccess
        )
        let plugin = CalendarPlugin(eventService: service)
        let stateChanged = expectation(description: "calendar permission state changed")
        plugin.onStateChange = {
            stateChanged.fulfill()
        }

        plugin.handlePermissionAction(id: "calendar-events")

        await fulfillment(of: [stateChanged], timeout: 1)
        XCTAssertEqual(service.requestAccessCallCount, 1)
    }
}

@MainActor
private final class MockCalendarPermissionService: CalendarEventServicing {
    var authorization: CalendarEventAuthorization
    private let requestResult: CalendarEventAuthorization
    private(set) var requestAccessCallCount = 0

    init(authorization: CalendarEventAuthorization, requestResult: CalendarEventAuthorization) {
        self.authorization = authorization
        self.requestResult = requestResult
    }

    func requestAccess() async -> CalendarEventAuthorization {
        requestAccessCallCount += 1
        authorization = requestResult
        return requestResult
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        []
    }

    func openSystemCalendar(at date: Date) {}
}
