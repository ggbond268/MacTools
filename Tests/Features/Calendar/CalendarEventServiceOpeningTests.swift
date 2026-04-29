import XCTest
@testable import MacTools

@MainActor
final class CalendarEventServiceOpeningTests: XCTestCase {
    func testOpeningScriptUsesCalendarDateLiteral() throws {
        let calendar = Self.makeCalendar()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29)))

        let script = CalendarEventService.openingScript(for: date, dateFormatter: formatter)

        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains("switch view to day view"))
        XCTAssertTrue(script.contains("view calendar at date \"Wednesday, April 29, 2026\""))
        XCTAssertFalse(script.contains("set targetDate"))
    }

    func testOpeningScriptEscapesDateTextForAppleScriptLiteral() throws {
        let calendar = Self.makeCalendar()
        let formatter = QuotedDateFormatter(calendar: calendar)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29)))

        let script = CalendarEventService.openingScript(for: date, dateFormatter: formatter)

        XCTAssertTrue(script.contains("view calendar at date \"A\\\"B\\\\C\""))
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private final class QuotedDateFormatter: DateFormatter, @unchecked Sendable {
    init(calendar: Calendar) {
        super.init()
        self.calendar = calendar
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func string(from date: Date) -> String {
        "A\"B\\C"
    }
}
