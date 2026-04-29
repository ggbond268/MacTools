import XCTest
@testable import MacTools

final class CalendarHolidayProviderTests: XCTestCase {
    func testDecodesSupportedHolidayKindsAndIgnoresUnknownDates() throws {
        let calendar = Self.makeCalendar()
        let provider = try CalendarHolidayProvider(
            data: #"{"2026":{"0101":2,"0104":1,"0201":9}}"#.data(using: .utf8)!
        )

        XCTAssertEqual(
            provider.kind(for: try Self.date(year: 2026, month: 1, day: 1, calendar: calendar), calendar: calendar),
            .holiday
        )
        XCTAssertEqual(
            provider.kind(for: try Self.date(year: 2026, month: 1, day: 4, calendar: calendar), calendar: calendar),
            .workday
        )
        XCTAssertNil(provider.kind(for: try Self.date(year: 2026, month: 2, day: 1, calendar: calendar), calendar: calendar))
        XCTAssertNil(provider.kind(for: try Self.date(year: 2027, month: 1, day: 1, calendar: calendar), calendar: calendar))
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
