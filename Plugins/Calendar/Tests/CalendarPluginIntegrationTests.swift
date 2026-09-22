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
            plugins: [CalendarPlugin(context: makeContext(defaults: defaults), eventService: MockCalendarPermissionService(
                authorization: .fullAccess, requestResult: .fullAccess
            ))],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["calendar"])
        XCTAssertEqual(host.componentItems.first?.span.width, 4)
        XCTAssertEqual(host.componentItems.first?.span.height, 38)
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

    func testRecentAgendaToggleUpdatesCachedContentAndComponentHeight() async throws {
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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let cachedContent = host.componentViewItem(for: host.testEntry(pluginID: "calendar", kind: .widget).id, dismiss: {}).content
        let view = NSHostingView(rootView: cachedContent.background(Color.white))
        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.frame = CGRect(x: 0, y: 0, width: 304, height: 504)
        try await settleLayout(view)
        let visibleDetails = try snapshot(view)
        let detailsSpan = try XCTUnwrap(host.componentItems.first?.span.height)
        XCTAssertGreaterThan(detailsSpan, 38, "Missing access still needs permission guidance")

        host.performSettingsAction(
            pluginID: "calendar",
            action: .setBoolean(controlID: "show-recent-agenda", value: false)
        )

        XCTAssertTrue(host.isComponentViewCached(for: host.testEntry(pluginID: "calendar", kind: .widget).id))
        XCTAssertEqual(host.componentItems.first?.span.height, 38)
        XCTAssertNotEqual(try snapshot(view), visibleDetails)

        host.performSettingsAction(
            pluginID: "calendar",
            action: .setBoolean(controlID: "show-recent-agenda", value: true)
        )

        try await settleLayout(view)
        XCTAssertEqual(host.componentItems.first?.span.height, detailsSpan)
        XCTAssertEqual(try snapshot(view), visibleDetails)
    }

    func testRenderedAgendaResizesHostAndShrinksWhenEventsDisappear() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let service = MockCalendarPermissionService(authorization: .fullAccess, requestResult: .fullAccess)
        let plugin = CalendarPlugin(context: makeContext(defaults: defaults), eventService: service)
        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let view = NSHostingView(rootView: host.componentViewItem(for: host.testEntry(pluginID: "calendar", kind: .widget).id, dismiss: {}).content
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.frame = CGRect(x: 0, y: 0, width: 304, height: 504)
        plugin.panelItemDidBecomeVisible("widget")
        defer { plugin.panelItemDidBecomeHidden("widget") }
        try await settleLayout(view)

        let emptySpan = try XCTUnwrap(host.componentItems.first?.span.height)
        XCTAssertEqual(emptySpan, 38, "An empty agenda must preserve the original month-only height")
        try attachSnapshot(view, spanHeight: emptySpan, name: "Calendar-empty-agenda")
        let emptyAppearance = try snapshot(view)
        host.performSettingsAction(
            pluginID: "calendar", action: .setBoolean(controlID: "show-recent-agenda", value: false)
        )
        try await settleLayout(view)
        XCTAssertEqual(try snapshot(view), emptyAppearance, "An empty enabled agenda must look identical to a disabled agenda")
        host.performSettingsAction(
            pluginID: "calendar", action: .setBoolean(controlID: "show-recent-agenda", value: true)
        )
        try await settleLayout(view)
        XCTAssertEqual(try snapshot(view), emptyAppearance)

        var previousSpan = emptySpan
        for count in [1, 3, 12, 0] {
            service.eventInputs = (0..<count).map { index in
                let start = Calendar.current.startOfDay(for: Date())
                return CalendarEventInput(
                    id: "event-\(index)", title: "Event \(index)", startDate: start,
                    endDate: start.addingTimeInterval(3600), isAllDay: false, color: .accent
                )
            }
            plugin.panelItemDidBecomeHidden("widget")
            plugin.panelItemDidBecomeVisible("widget")
            try await settleLayout(view)

            let span = try XCTUnwrap(host.componentItems.first?.span.height)
            XCTAssertEqual(span, plugin.descriptor.span.height, "The host must receive the new size")
            if count == 0 {
                XCTAssertEqual(span, emptySpan, "Removing events must release their reserved space")
                view.setFrameSize(NSSize(width: 304, height: 304))
                XCTAssertEqual(try snapshot(view), emptyAppearance, "Removing the last event must restore the original month appearance")
            } else {
                XCTAssertGreaterThan(span, emptySpan)
                XCTAssertLessThanOrEqual(span, 104, "Long agendas must scroll within the expanded bounded list")
                if count == 3 {
                    XCTAssertGreaterThan(span, previousSpan, "Three rows need more room than one")
                    try attachSnapshot(view, spanHeight: span, name: "Calendar-three-events")
                }
            }
            previousSpan = span
        }

        service.authorization = .denied("Calendar access denied")
        plugin.panelItemDidBecomeHidden("widget")
        plugin.panelItemDidBecomeVisible("widget")
        try await settleLayout(view)
        XCTAssertGreaterThan(try XCTUnwrap(host.componentItems.first?.span.height), emptySpan)
        XCTAssertLessThanOrEqual(try XCTUnwrap(host.componentItems.first?.span.height), 48)
    }

    func testLibraryPreviewDoesNotResizeLiveCalendar() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let plugin = CalendarPlugin(context: makeContext(defaults: defaults))
        plugin.componentContentHeightDidChange(501)
        let span = plugin.descriptor.span
        var changes = 0
        plugin.onStateChange = { changes += 1 }
        let view = NSHostingView(rootView: plugin.makeView(context: PluginPanelWidgetContext(
            pluginID: "calendar", itemID: "widget", placementID: nil, dismiss: {}
        )))
        view.frame = CGRect(x: 0, y: 0, width: 304, height: 504)

        try await settleLayout(view)

        XCTAssertEqual(plugin.descriptor.span, span)
        XCTAssertEqual(changes, 0)
    }

    func testAgendaSettingsExposeDefaultsAndPersistValidatedActions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let plugin = CalendarPlugin(context: makeContext(defaults: defaults))
        let initialRows = try agendaRows(plugin)
        guard case let .picker(direction, _, style) = initialRows[1].control,
              case .segmented = style,
              case let .picker(count, options, _) = initialRows[2].control else {
            return XCTFail("Range controls must use the shared settings pickers")
        }
        XCTAssertEqual(direction, "future")
        XCTAssertEqual(count, "3")
        XCTAssertEqual(options.map(\.id), (1...7).map(String.init))

        plugin.handleSettingsAction(.setSelection(controlID: "agenda-direction", optionID: "surrounding"))
        plugin.handleSettingsAction(.setSelection(controlID: "agenda-day-count", optionID: "7"))
        plugin.handleSettingsAction(.setSelection(controlID: "agenda-day-count", optionID: "8"))
        plugin.handleSettingsAction(.setSelection(controlID: "agenda-direction", optionID: "invalid"))
        plugin.handleSettingsAction(.setBoolean(controlID: "show-recent-agenda", value: false))

        let restored = CalendarPlugin(context: makeContext(defaults: defaults))
        let rows = try agendaRows(restored)
        guard case .toggle(isOn: false) = rows[0].control,
              case .picker(selectionID: "surrounding", _, _) = rows[1].control,
              case .picker(selectionID: "7", _, _) = rows[2].control else {
            return XCTFail("Valid settings must persist and invalid settings must be ignored")
        }
        XCTAssertFalse(rows[1].isEnabled)
        XCTAssertFalse(rows[2].isEnabled)
        XCTAssertEqual(restored.descriptor.span.height, 38)
    }

    func testGroupedAgendaRendersInBothAppearancesAndResizesAfterRangeChange() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let service = MockCalendarPermissionService(authorization: .fullAccess, requestResult: .fullAccess)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        service.eventInputs = (0...2).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let start = calendar.date(byAdding: .hour, value: 10, to: day)!
            return CalendarEventInput(id: "day-\(offset)", title: ["Design review", "Project planning", "Release check"][offset],
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: offset == 1,
                color: offset == 1 ? CalendarEventColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1) : .accent,
                calendarTitle: offset == 1 ? "Personal" : "Work")
        }
        let plugin = CalendarPlugin(context: makeContext(defaults: defaults), eventService: service)
        plugin.panelItemDidBecomeVisible("widget")
        defer { plugin.panelItemDidBecomeHidden("widget") }
        plugin.handleSettingsAction(.setSelection(controlID: "alternate-calendar", optionID: "chinese"))
        var appearances = [ColorScheme.light, .dark].map { scheme in
            (name: "system-\(scheme)", scheme: scheme, contrast: ColorSchemeContrast.standard,
             theme: PluginComponentTheme.system(colorScheme: scheme, contrast: .standard))
        }
        for id in ["builtin.solarized-light", "builtin.catppuccin-mocha"] {
            let definition = try XCTUnwrap(MenuBarPanelBuiltInThemes.all.first { $0.id == id })
            let scheme = MenuBarPanelThemeResolver.colorScheme(for: definition.appearance)
            for contrast in [ColorSchemeContrast.standard, .increased] {
                appearances.append((name: "\(id)-\(contrast)", scheme: scheme, contrast: contrast,
                    theme: MenuBarPanelThemeResolver.resolve(definition: definition,
                        colorScheme: scheme, contrast: contrast).componentTheme))
            }
        }
        for appearance in appearances {
            let scheme = appearance.scheme
            let theme = appearance.theme
            let view = NSHostingView(rootView: plugin.makeView(context: PluginPanelWidgetContext(
                pluginID: "calendar", itemID: "widget", placementID: UUID(), dismiss: {}
            ))
            .foregroundStyle(theme.text.primary)
            .environment(\.pluginComponentTheme, theme)
            .environment(\.colorScheme, scheme)
            .background(theme.surfaces.panel))
            let nativeAppearance: NSAppearance.Name = appearance.contrast == .increased
                ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : (scheme == .dark ? .darkAqua : .aqua)
            view.appearance = NSAppearance(named: nativeAppearance)
            view.frame = CGRect(x: 0, y: 0, width: 304, height: 608)
            try await settleLayout(view)
            let groupedHeight = plugin.descriptor.span.height
            XCTAssertLessThanOrEqual(groupedHeight, 76)
            try attachSnapshot(view, spanHeight: groupedHeight, name: "Calendar-grouped-\(appearance.name)")

            plugin.handleSettingsAction(.setSelection(controlID: "agenda-day-count", optionID: "1"))
            try await settleLayout(view)
            XCTAssertLessThan(plugin.descriptor.span.height, groupedHeight)
            plugin.handleSettingsAction(.setSelection(controlID: "agenda-day-count", optionID: "3"))
            try await settleLayout(view)
            XCTAssertEqual(plugin.descriptor.span.height, groupedHeight)

            plugin.handleSettingsAction(.setSelection(controlID: "alternate-calendar", optionID: "none"))
            try await settleLayout(view)
            try attachSnapshot(view, spanHeight: plugin.descriptor.span.height, name: "Calendar-grouped-none-\(appearance.name)")
            plugin.handleSettingsAction(.setSelection(controlID: "alternate-calendar", optionID: "chinese"))
            try await settleLayout(view)
            XCTAssertEqual(plugin.descriptor.span.height, groupedHeight)
        }
    }

    func testAlternateCalendarMenuUpdatesCachedCalendarAndPersistsValidatedChoice() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let context = makeContext(defaults: defaults)
        let plugin = CalendarPlugin(context: context, eventService: MockCalendarPermissionService(
            authorization: .fullAccess, requestResult: .fullAccess
        ))
        let host = PluginHost(plugins: [plugin], shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager())
        guard case let .form(sections) = try XCTUnwrap(plugin.settingsPage).body,
              case let .rows(rows) = try XCTUnwrap(sections.first).content,
              case let .picker(selection, options, style) = try XCTUnwrap(rows.first { $0.id == "alternate-calendar" }).control,
              case .menu = style else {
            return XCTFail("Alternate calendars must use a menu with None and Chinese lunar calendar options")
        }
        XCTAssertEqual(selection, CalendarDisplayPolicy.defaultAlternateCalendar().rawValue)
        XCTAssertEqual(options.map(\.id), ["none", "chinese"])
        for scheme in [ColorScheme.light, .dark] {
            let theme = PluginComponentTheme.system(colorScheme: scheme, contrast: .standard)
            let view = NSHostingView(rootView: host.componentViewItem(for: host.testEntry(pluginID: "calendar", kind: .widget).id, dismiss: {}).content
                .environment(\.pluginComponentTheme, theme)
                .environment(\.colorScheme, scheme)
                .background(theme.surfaces.panel))
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 304, height: 304)
            host.performSettingsAction(pluginID: "calendar", action: .setSelection(controlID: "alternate-calendar", optionID: "chinese"))
            try await settleLayout(view)
            let lunar = try snapshot(view)
            try attachSnapshot(view, spanHeight: 38, name: "Calendar-alternate-chinese-\(scheme)")
            host.performSettingsAction(pluginID: "calendar", action: .setSelection(controlID: "alternate-calendar", optionID: "none"))
            try await settleLayout(view)
            XCTAssertNotEqual(try snapshot(view), lunar)
            try attachSnapshot(view, spanHeight: 38, name: "Calendar-alternate-none-\(scheme)")
            XCTAssertTrue(host.isComponentViewCached(for: host.testEntry(pluginID: "calendar", kind: .widget).id))
            XCTAssertEqual(plugin.descriptor.span.height, 38)
        }
        host.performSettingsAction(pluginID: "calendar", action: .setSelection(controlID: "alternate-calendar", optionID: "invalid"))
        XCTAssertEqual(CalendarSettingsStore(storage: context.storage).alternateCalendar, .none)
    }

    private func agendaRows(_ plugin: CalendarPlugin) throws -> [PluginSettingsRow] {
        guard case let .form(sections) = try XCTUnwrap(plugin.settingsPage).body,
              let section = sections.first(where: { $0.id == "calendar-agenda" }),
              case let .rows(rows) = section.content else {
            XCTFail("The agenda must be a declarative settings section")
            return []
        }
        return rows
    }

    private func settleLayout(_ view: NSView) async throws {
        for _ in 0..<15 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func attachSnapshot(_ view: NSView, spanHeight: Int, name: String) throws {
        view.setFrameSize(NSSize(
            width: 304,
            height: PluginPanelWidgetLayoutMetrics.default.itemHeight(forSpanHeight: spanHeight)
        ))
        let attachment = XCTAttachment(data: try snapshot(view), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    var eventInputs: [CalendarEventInput] = []

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
        eventInputs
    }

    func openSystemCalendar(at date: Date) {}
}
