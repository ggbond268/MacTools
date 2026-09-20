import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import CalendarPlugin

@MainActor
final class CalendarLayoutStabilityTests: XCTestCase {
    func testRapidMonthNavigationKeepsAgendaHeightUntilLatestResult() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.model.start()
        try await waitForRequests(1, in: fixture.service)
        fixture.service.complete(0, with: .success(fixture.events))
        try await settle(fixture.view)
        let height = try XCTUnwrap(fixture.heights.values.last)
        XCTAssertGreaterThan(height, 298)
        fixture.heights.values = []

        for (index, offset) in [1, 1, -1].enumerated() {
            fixture.model.moveMonth(by: offset)
            XCTAssertTrue(fixture.model.hasAgendaContent, "Month navigation must not clear the recent agenda")
            try await waitForRequests(index + 2, in: fixture.service)
            try await settle(fixture.view)
            XCTAssertEqual(fixture.model.agendaDays.first?.events.map(\.title), fixture.events.map(\.title))
        }

        // Resolve the latest month query before its separate recent-events query.
        fixture.service.complete(3, with: .success([]))
        try await waitForRequests(5, in: fixture.service)
        try await settle(fixture.view)
        XCTAssertTrue(fixture.model.hasAgendaContent, "The month and agenda results must publish together")
        fixture.service.complete(1, with: .success([]))
        fixture.service.complete(2, with: .failure(CocoaError(.fileReadUnknown)))
        try await settle(fixture.view)
        XCTAssertNil(fixture.model.eventLoadingError, "Cancelled requests must not overwrite the latest state")
        XCTAssertTrue(fixture.model.hasAgendaContent)
        fixture.service.complete(4, with: .success(fixture.events))
        try await settle(fixture.view)

        fixture.model.goToToday()
        try await waitForRequests(6, in: fixture.service)
        try await settle(fixture.view)
        XCTAssertTrue(fixture.model.hasAgendaContent)
        XCTAssertTrue(fixture.heights.values.allSatisfy { abs($0 - height) < 0.5 },
            "Unchanged agenda content must never pass through a smaller height: \(fixture.heights.values)")

        // A confirmed empty result must still reclaim the entire footer.
        fixture.service.complete(5, with: .success([]))
        try await settle(fixture.view)
        XCTAssertFalse(fixture.model.hasAgendaContent)
        XCTAssertEqual(try XCTUnwrap(fixture.heights.values.last), 298, accuracy: 0.5)
    }

    func testNewAgendaPublishesIntrinsicHeightWithoutAnEstimatedIntermediateHeight() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.model.start()
        try await waitForRequests(1, in: fixture.service)
        try await settle(fixture.view)
        fixture.heights.values = []

        fixture.service.complete(0, with: .success(fixture.events))
        try await settle(fixture.view)

        XCTAssertFalse(fixture.heights.values.isEmpty)
        XCTAssertEqual(Set(fixture.heights.values.map { Int($0.rounded()) }).count, 1,
            "The parent must not resize once for an estimate and again for the actual list: \(fixture.heights.values)")
        XCTAssertGreaterThan(try XCTUnwrap(fixture.heights.values.last), 298)
    }

    func testRetryRetainsErrorFooterWhileRequestIsPending() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.model.start()
        try await waitForRequests(1, in: fixture.service)
        fixture.service.complete(0, with: .failure(CocoaError(.fileReadUnknown)))
        try await settle(fixture.view)
        let height = try XCTUnwrap(fixture.heights.values.last)
        fixture.heights.values = []

        fixture.model.refresh()
        try await waitForRequests(2, in: fixture.service)
        try await settle(fixture.view)

        XCTAssertTrue(fixture.model.hasAgendaContent)
        XCTAssertNotNil(fixture.model.eventLoadingError)
        XCTAssertTrue(fixture.heights.values.allSatisfy { abs($0 - height) < 0.5 })
        fixture.service.complete(1, with: .success([]))
        try await settle(fixture.view)
        XCTAssertFalse(fixture.model.hasAgendaContent)
        XCTAssertEqual(try XCTUnwrap(fixture.heights.values.last), 298, accuracy: 0.5)
    }

    func testLongAgendaUsesScrollableViewportAndShortAgendaReturnsToIntrinsicHeight() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let window = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 304, height: 824),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = fixture.view
        PluginPresentationSafety.prepareForWindowOrdering(window, windows: [window])
        window.orderFront(nil)
        defer { window.close() }
        fixture.model.start()
        try await waitForRequests(1, in: fixture.service)
        let start = try XCTUnwrap(fixture.events.first?.startDate)
        let events = (0..<20).map { index in
            CalendarEventInput(id: "long-\(index)", title: "Event \(index)", startDate: start,
                endDate: start.addingTimeInterval(3600), isAllDay: false, color: .accent)
        }
        fixture.service.complete(0, with: .success(Array(events.prefix(10))))
        try await settle(fixture.view)
        let tenEventHeight = try XCTUnwrap(fixture.heights.values.last)
        XCTAssertTrue(descendants(fixture.view).compactMap { $0 as? NSScrollView }.isEmpty,
            "Ten regular events should fit before the agenda needs to scroll")

        fixture.model.refresh()
        try await waitForRequests(2, in: fixture.service)
        fixture.service.complete(1, with: .success(events))
        try await settle(fixture.view)
        window.displayIfNeeded()
        let longHeight = try XCTUnwrap(fixture.heights.values.last)
        XCTAssertGreaterThan(longHeight, tenEventHeight)
        let scrollView = try XCTUnwrap(descendants(fixture.view).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scrollView.documentView)
        XCTAssertEqual(scrollView.contentSize.height, CalendarComponentLayout.maximumAgendaListHeight, accuracy: 1)
        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        scrollView.flashScrollers()
        XCTAssertFalse(hasVisibleScroller(scrollView.verticalScroller), "Scrolling must not display a vertical scrollbar")
        XCTAssertFalse(hasVisibleScroller(scrollView.horizontalScroller))
        scrollView.scrollerStyle = .legacy
        scrollView.flashScrollers()
        XCTAssertFalse(hasVisibleScroller(scrollView.verticalScroller), "The scrollbar must also stay hidden with legacy scrollers")
        XCTAssertEqual(scrollView.contentSize.width, scrollView.bounds.width, accuracy: 1,
            "Hidden scrollbars must not reserve a gutter beside the events")
        XCTAssertGreaterThan(document.bounds.height, scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scrollView.contentSize.height))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertGreaterThan(scrollView.documentVisibleRect.minY, 0, "Events below the cap must remain scrollable")

        fixture.model.refresh()
        try await waitForRequests(3, in: fixture.service)
        fixture.service.complete(2, with: .success(Array(fixture.events.prefix(1))))
        try await settle(fixture.view)
        XCTAssertLessThan(try XCTUnwrap(fixture.heights.values.last), longHeight)
        XCTAssertTrue(descendants(fixture.view).compactMap { $0 as? NSScrollView }.isEmpty)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func hasVisibleScroller(_ scroller: NSScroller?) -> Bool {
        guard let scroller, scroller.window != nil else { return false }
        return !scroller.isHiddenOrHasHiddenAncestor && scroller.alphaValue > 0
    }

    private func makeFixture() throws -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let suite = "CalendarLayoutStabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let context = PluginRuntimeContext(pluginID: "calendar",
            storage: UserDefaultsPluginStorage(pluginID: "calendar", userDefaults: defaults))
        let settings = CalendarSettingsStore(storage: context.storage)
        let service = DeferredCalendarEventService()
        let model = CalendarComponentViewModel(eventService: service, holidayProvider: .empty,
            calendar: calendar, notificationCenter: NotificationCenter(), today: today, now: { today })
        let heights = Heights()
        let view = NSHostingView(rootView: CalendarComponentView(
            context: PluginComponentContext(pluginID: "calendar", dismiss: {}, isPanelVisible: true),
            viewModel: model, settingsStore: settings, onContentHeightChange: { heights.values.append($0) }
        ))
        view.frame = NSRect(x: 0, y: 0, width: 304, height: 608)
        let events = (0..<3).map { index in
            CalendarEventInput(id: "\(index)", title: "Event \(index)", startDate: today.addingTimeInterval(3600),
                endDate: today.addingTimeInterval(7200), isAllDay: false, color: .accent)
        }
        return Fixture(model: model, service: service, view: view, heights: heights,
            events: events, defaults: defaults, suite: suite)
    }

    private func waitForRequests(_ count: Int, in service: DeferredCalendarEventService) async throws {
        for _ in 0..<100 {
            if service.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(count) requests, received \(service.requests.count)")
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class Heights {
        var values: [CGFloat] = []
    }

    @MainActor
    private struct Fixture {
        let model: CalendarComponentViewModel
        let service: DeferredCalendarEventService
        let view: NSView
        let heights: Heights
        let events: [CalendarEventInput]
        let defaults: UserDefaults
        let suite: String

        func close() {
            model.stop()
            service.cancelAll()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class DeferredCalendarEventService: CalendarEventServicing {
    var authorization: CalendarEventAuthorization = .fullAccess
    private(set) var requests: [CheckedContinuation<[CalendarEventInput], Error>?] = []

    func requestAccess() async -> CalendarEventAuthorization { authorization }
    func openSystemCalendar(at date: Date) {}

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func complete(_ index: Int, with result: Result<[CalendarEventInput], Error>) {
        guard requests.indices.contains(index), let continuation = requests[index] else { return }
        requests[index] = nil
        continuation.resume(with: result)
    }

    func cancelAll() {
        for index in requests.indices { complete(index, with: .failure(CancellationError())) }
    }
}
