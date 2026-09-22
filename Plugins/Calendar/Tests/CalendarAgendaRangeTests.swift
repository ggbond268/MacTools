import XCTest
@testable import CalendarPlugin

final class CalendarAgendaRangeTests: XCTestCase {
    func testEveryDirectionKeepsTheRequestedTotalDaysAndIncludesToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 14)))
        let start = calendar.startOfDay(for: today)
        for direction in CalendarAgendaDirection.allCases {
            for count in 1...7 {
                let dates = CalendarAgendaRange(dayCount: count, direction: direction).dates(relativeTo: today, calendar: calendar)
                XCTAssertEqual(dates.count, count)
                XCTAssertEqual(Set(dates).count, count)
                XCTAssertTrue(dates.contains(start))
                XCTAssertEqual(dates, dates.sorted())
                let offsets = dates.map { calendar.dateComponents([.day], from: start, to: $0).day! }
                switch direction {
                case .past: XCTAssertEqual(offsets, Array((1 - count)...0))
                case .future: XCTAssertEqual(offsets, Array(0..<count))
                case .surrounding:
                    XCTAssertEqual(offsets.first, -((count - 1) / 2))
                    XCTAssertEqual(offsets.last, count / 2)
                }
            }
        }
    }

    func testRangeUsesCalendarDaysAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let dates = CalendarAgendaRange(dayCount: 3, direction: .surrounding).dates(relativeTo: today, calendar: calendar)

        XCTAssertEqual(dates.map { calendar.component(.day, from: $0) }, [7, 8, 9])
        XCTAssertTrue(dates.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        XCTAssertEqual(dates[2].timeIntervalSince(dates[1]), 23 * 3600)
    }
}
