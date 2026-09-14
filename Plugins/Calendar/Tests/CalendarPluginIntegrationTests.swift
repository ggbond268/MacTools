import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import CalendarPlugin

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
            plugins: [CalendarPlugin(context: makeContext(defaults: defaults))],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.id), ["calendar"])
        XCTAssertEqual(host.componentItems.first?.span.width, 4)
        XCTAssertEqual(host.componentItems.first?.span.height, 63)
        XCTAssertEqual(host.permissionCards.map(\.permissionID), ["calendar-events", "calendar-automation"])
        XCTAssertEqual(host.pluginSettingsItems.map(\.id), ["calendar"])
        XCTAssertEqual(host.pluginSettingsItems.first?.layout, .form)
        XCTAssertEqual(host.pluginSettingsItems.first?.permissionCards.map(\.permissionID), [
            "calendar-events",
            "calendar-automation"
        ])
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

    func testTodayDetailsToggleUpdatesCachedContentAndComponentHeight() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let plugin = CalendarPlugin(
            context: makeContext(defaults: defaults),
            eventService: MockCalendarPermissionService(
                authorization: .notDetermined,
                requestResult: .notDetermined
            )
        )
        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let cachedContent = host.componentViewItem(for: "calendar", dismiss: {}).content
        let view = NSHostingView(rootView: cachedContent.background(Color.white))
        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.frame = CGRect(x: 0, y: 0, width: 304, height: 504)
        let visibleDetails = try snapshot(view)
        XCTAssertEqual(host.componentItems.first?.span.height, 63)

        host.performSettingsAction(
            pluginID: "calendar",
            action: .setBoolean(controlID: "show-today-details", value: false)
        )

        XCTAssertTrue(host.isComponentViewCached(for: "calendar"))
        XCTAssertEqual(host.componentItems.first?.span.height, 37)
        XCTAssertNotEqual(try snapshot(view), visibleDetails)

        host.performSettingsAction(
            pluginID: "calendar",
            action: .setBoolean(controlID: "show-today-details", value: true)
        )

        XCTAssertEqual(host.componentItems.first?.span.height, 63)
        XCTAssertEqual(try snapshot(view), visibleDetails)
    }

    private func makeContext(defaults: UserDefaults) -> PluginRuntimeContext {
        PluginRuntimeContext(
            pluginID: "calendar",
            storage: UserDefaultsPluginStorage(pluginID: "calendar", userDefaults: defaults)
        )
    }

    private func snapshot(_ view: NSView) throws -> Data {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
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
