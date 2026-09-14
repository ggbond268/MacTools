# US-plugins-calendar-today-details — Keep Calendar Details on Today

Last verified: 2026-09-14

| Field | Value |
| ----- | ------ |
| ID | `US-plugins-calendar-today-details` |
| Status | `ready` |
| Domain | `plugins` |
| Actor | `MacTools user` |

## User Story

> As a MacTools user, when I browse or hover dates in Calendar, I want the lower details area to stay on today and be optional so that I can avoid duplicate date details while keeping today's lunar date and agenda visible.

## Acceptance

- Given the lower details setting is unset, then the Calendar component shows today's date, full lunar date, and agenda below the monthly grid.
- When the user hovers or selects another day, then the lower details remain on today and the existing hover popover shows that day's details.
- When the user disables the Calendar lower details setting, then an already displayed component hides the details immediately and returns to its compact height.
- When the user enables the setting again, then the details and their reserved height return immediately.
- When a cross-day event overlaps both today and a separately queried month grid, then it appears once on each applicable day.
- When the user reopens MacTools, then the stored lower details setting is retained.

## References

| Type | Source |
| ---- | ------ |
| Feature | `docs/features/calendar-selected-day-details.md` |
| Code | `Plugins/Calendar/Sources/CalendarComponentViewModel.swift` |
| Settings | `Plugins/Calendar/Sources/CalendarSettings.swift` |
| Test | `Plugins/Calendar/Tests/CalendarComponentViewModelTests.swift` |
| Test | `Plugins/Calendar/Tests/CalendarPluginIntegrationTests.swift` |

## History

| Date | Type | Previous | New | Source |
| ---- | ---- | -------- | --- | ------ |
| 2026-09-14 | created | — | Fixed-today details and default-on visibility contract | PR #368 comment #5645830568 |
