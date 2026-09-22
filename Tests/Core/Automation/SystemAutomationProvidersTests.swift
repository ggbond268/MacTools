import EventKit
import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

final class SystemAutomationProvidersTests: XCTestCase {

    func testScheduleFindsNextConfiguredWeekdayWithoutCatchUp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let mondayMorning = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 10))
        )
        let configuration = ScheduleAutomationTrigger(hour: 9, minute: 0, weekdays: [2, 4])

        let next = try XCTUnwrap(
            SystemScheduleAutomationTriggerProvider.nextFireDate(
                for: configuration,
                after: mondayMorning,
                calendar: calendar
            )
        )

        XCTAssertEqual(calendar.component(.weekday, from: next), 4)
        XCTAssertEqual(calendar.component(.hour, from: next), 9)
        XCTAssertGreaterThan(next, mondayMorning)
    }

    func testPowerTransitionsEmitSourceAndThresholdCrossingsOnlyOnce() {
        let date = Date(timeIntervalSince1970: 100)
        let events = SystemAutomationTransitions.powerEvents(
            previous: AutomationPowerSnapshot(source: .adapter, batteryLevel: 55),
            current: AutomationPowerSnapshot(source: .battery, batteryLevel: 39),
            thresholds: [20, 40, 50],
            date: date
        )

        XCTAssertEqual(
            events,
            [
                .power(source: .battery, batteryLevel: 39, event: .adapterDisconnected, date: date),
                .power(source: .battery, batteryLevel: 50, event: .batteryAtOrBelow, date: date),
                .power(source: .battery, batteryLevel: 40, event: .batteryAtOrBelow, date: date),
            ]
        )
        XCTAssertTrue(
            SystemAutomationTransitions.powerEvents(
                previous: AutomationPowerSnapshot(source: .battery, batteryLevel: 39),
                current: AutomationPowerSnapshot(source: .battery, batteryLevel: 39),
                thresholds: [40],
                date: date
            ).isEmpty
        )
    }

    func testNetworkTransitionsSeparateAvailabilityFromInterfaceChanges() {
        let date = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            SystemAutomationTransitions.networkEvents(
                previousStatus: .available,
                previousInterface: .wifi,
                currentStatus: .available,
                currentInterface: .wiredEthernet,
                date: date
            ),
            [.network(status: .available, interface: .wiredEthernet, date: date)]
        )
        XCTAssertEqual(
            SystemAutomationTransitions.networkEvents(
                previousStatus: .unavailable,
                previousInterface: .any,
                currentStatus: .available,
                currentInterface: .wifi,
                date: date
            ),
            [
                .network(status: .available, interface: .any, date: date),
                .network(status: .available, interface: .wifi, date: date),
            ]
        )
    }

    func testCalendarQueryIncludesEndedEventsWithFuturePositiveOffsets() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            SystemCalendarAutomationTriggerProvider.queryStartDate(
                currentDate: now,
                configurations: [
                    CalendarAutomationTrigger(phase: .ends, offsetMinutes: 30),
                    CalendarAutomationTrigger(phase: .starts, offsetMinutes: -10),
                ]
            ),
            now.addingTimeInterval(-30 * 60)
        )
    }

    func testDisplayTransitionsPreserveDisconnectedDisplayMetadata() {
        let date = Date(timeIntervalSince1970: 100)
        let builtIn = AutomationDisplaySnapshot(identifier: "1", name: "Built-in")
        let oldExternal = AutomationDisplaySnapshot(identifier: "2", name: "Studio")
        let newExternal = AutomationDisplaySnapshot(identifier: "3", name: "Projector")

        let events = SystemAutomationTransitions.displayEvents(
            previous: [builtIn, oldExternal],
            current: [builtIn, newExternal],
            date: date
        )

        XCTAssertEqual(
            events,
            [
                .display(newExternal, event: .connected, date: date),
                .display(oldExternal, event: .disconnected, date: date),
            ]
        )
    }

    @MainActor
    func testCalendarPlanBatchesSimultaneousEventsAndExcludesLaterOnes() {
        let now = Date(timeIntervalSince1970: 100)
        let firstDate = now.addingTimeInterval(60)
        let laterDate = now.addingTimeInterval(120)
        let events = [
            calendarEvent(id: "second", date: firstDate),
            calendarEvent(id: "later", date: laterDate),
            calendarEvent(id: "first", date: firstDate),
        ]

        let plan = SystemCalendarAutomationTriggerProvider.SchedulePlan.make(
            candidates: events,
            after: now
        )

        XCTAssertEqual(plan.nextBatch.map(\.identifier), ["first", "second"])
        XCTAssertEqual(plan.dueEvents(at: firstDate), plan.nextBatch)
        XCTAssertTrue(plan.dueEvents(at: firstDate.addingTimeInterval(91)).isEmpty)
    }

    @MainActor
    private func calendarEvent(
        id: String,
        date: Date
    ) -> SystemCalendarAutomationTriggerProvider.ScheduledEvent {
        SystemCalendarAutomationTriggerProvider.ScheduledEvent(
            fireDate: date,
            identifier: id,
            title: id,
            calendarIdentifier: nil,
            phase: .starts,
            offsetMinutes: 0
        )
    }
}
