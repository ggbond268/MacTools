import AppKit
import EventKit
import Foundation

@MainActor
enum CalendarEventAuthorization: Equatable {
    case notDetermined
    case fullAccess
    case denied(String)

    var isFullAccess: Bool {
        if case .fullAccess = self {
            return true
        }

        return false
    }
}

@MainActor
protocol CalendarEventServicing: AnyObject {
    var authorization: CalendarEventAuthorization { get }

    func requestAccess() async -> CalendarEventAuthorization
    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput]
    func openSystemCalendar(at date: Date)
}

@MainActor
final class CalendarEventService: CalendarEventServicing {
    private var eventStore = EKEventStore()

    var authorization: CalendarEventAuthorization {
        Self.authorization(from: EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarEventAuthorization {
        guard authorization == .notDetermined else {
            return authorization
        }

        do {
            _ = try await eventStore.requestFullAccessToEvents()
            eventStore = EKEventStore()
            return authorization
        } catch {
            eventStore = EKEventStore()
            return .denied(error.localizedDescription)
        }
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        guard authorization.isFullAccess else {
            return []
        }

        let calendars = eventStore.calendars(for: .event)
        guard !calendars.isEmpty else {
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        return eventStore.events(matching: predicate).map(Self.input(from:))
    }

    func openSystemCalendar(at date: Date) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            _ = await requestAccess()
            openSystemCalendarAfterAccessCheck(at: date)
        }
    }

    private func openSystemCalendarAfterAccessCheck(at date: Date) {
        let script = Self.openingScript(for: date)
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        if error != nil {
            openCalendarApplication()
        }
    }

    private static func authorization(from status: EKAuthorizationStatus) -> CalendarEventAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .fullAccess
        case .denied:
            return .denied("未获得日历访问权限")
        case .restricted:
            return .denied("系统限制了日历访问")
        case .writeOnly:
            return .denied("仅允许写入日历，无法读取日程")
        @unknown default:
            return .denied("当前系统不允许读取日历")
        }
    }

    private static func input(from event: EKEvent) -> CalendarEventInput {
        CalendarEventInput(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "未命名日程",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            color: CalendarEventColor(nsColor: event.calendar.color)
        )
    }

    static func openingScript(for date: Date) -> String {
        openingScript(for: date, dateFormatter: appleScriptDateFormatter())
    }

    static func openingScript(for date: Date, dateFormatter: DateFormatter) -> String {
        let dateText = appleScriptEscapedString(dateFormatter.string(from: date))

        return """
        tell application "Calendar"
          activate
          switch view to day view
          view calendar at date "\(dateText)"
        end tell
        """
    }

    private static func appleScriptDateFormatter() -> DateFormatter {
        let calendar = CalendarComponentCalendars.gregorianFollowingSystem()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }

    private static func appleScriptEscapedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func openCalendarApplication() {
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: calendarURL, configuration: configuration) { runningApplication, error in
            if error != nil {
                NSWorkspace.shared.open(calendarURL)
                Task { @MainActor in
                    Self.activateRunningCalendarApplication()
                }
                return
            }

            runningApplication?.activate(options: [.activateAllWindows])
        }
    }

    private static func activateRunningCalendarApplication() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iCal")
            .first?
            .activate(options: [.activateAllWindows])
    }
}

private extension CalendarEventColor {
    init(nsColor: NSColor?) {
        guard let color = nsColor?.usingColorSpace(.deviceRGB) else {
            self = .accent
            return
        }

        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }
}
