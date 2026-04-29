import Foundation

struct CalendarHolidayProvider {
    private typealias RawData = [String: [String: Int]]

    static let empty = CalendarHolidayProvider(records: [:])

    private let records: [String: [String: CalendarHolidayKind]]

    init(data: Data) throws {
        let rawData = try JSONDecoder().decode(RawData.self, from: data)
        self.records = rawData.mapValues { days in
            days.reduce(into: [String: CalendarHolidayKind]()) { result, item in
                result[item.key] = CalendarHolidayKind(rawValue: item.value)
            }
        }
    }

    private init(records: [String: [String: CalendarHolidayKind]]) {
        self.records = records
    }

    static func bundled() -> CalendarHolidayProvider {
        guard let url = Bundle.main.url(forResource: "ChinaHolidayOverrides", withExtension: "json") else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: url)
            return try CalendarHolidayProvider(data: data)
        } catch {
            return .empty
        }
    }

    func kind(for date: Date, calendar: Calendar) -> CalendarHolidayKind? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }

        return records[String(year)]?[String(format: "%02d%02d", month, day)]
    }
}
